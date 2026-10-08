//============ Copyright (c) Valve Corporation, All rights reserved. ============
#include "flow_amf_encoder.h"

#include "driverlog.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <deque>

#ifdef _WIN32
#include <windows.h>
#include <d3d11.h>
#include <d3d11_3.h>
#include <d3dcompiler.h>

#include "core/Factory.h"
#include "core/Context.h"
#include "core/Surface.h"
#include "core/Buffer.h"
#include "core/Data.h"
#include "core/Result.h"
#include "components/VideoEncoderVCE.h"

using namespace amf;

namespace
{
	constexpr size_t kMaxReadyPackets = 2; // bound the AMD encoder's pipeline delay
	constexpr int64_t kQueryTimeoutMs = 200;

	// ---- AMF runtime (amfrt64.dll ships with the Radeon driver) --------------------------------

	struct AmfRuntime
	{
		HMODULE module = nullptr;
		AMFFactory *factory = nullptr;
		bool resolved = false;
		std::string error;
	};

	AmfRuntime LoadAmfRuntime()
	{
		AmfRuntime runtime;
		const HMODULE module = LoadLibraryW( AMF_DLL_NAME );
		if ( module == nullptr )
		{
			runtime.error = "amfrt64.dll not found (AMD driver not installed?)";
			return runtime;
		}
		const auto init = reinterpret_cast< AMFInit_Fn >( GetProcAddress( module, AMF_INIT_FUNCTION_NAME ) );
		if ( init == nullptr )
		{
			FreeLibrary( module );
			runtime.error = "amfrt64.dll does not export AMFInit";
			return runtime;
		}
		AMFFactory *factory = nullptr;
		const AMF_RESULT result = init( AMF_FULL_VERSION, &factory );
		if ( result != AMF_OK || factory == nullptr )
		{
			FreeLibrary( module );
			char buffer[ 96 ];
			std::snprintf( buffer, sizeof( buffer ), "AMFInit failed status=0x%08x", static_cast< unsigned int >( result ) );
			runtime.error = buffer;
			return runtime;
		}
		// Kept for the whole process: both the driver and the helper create and drop encoders
		// when the stream size changes, and reloading the runtime each time is pointless.
		runtime.module = module;
		runtime.factory = factory;
		runtime.resolved = true;
		return runtime;
	}

	AmfRuntime &GetAmfRuntime()
	{
		static AmfRuntime runtime = LoadAmfRuntime();
		return runtime;
	}

	const char *AmfStatusName( AMF_RESULT status )
	{
		switch ( status )
		{
		case AMF_OK:
			return "AMF_OK";
		case AMF_FAIL:
			return "AMF_FAIL";
		case AMF_NOT_SUPPORTED:
			return "AMF_NOT_SUPPORTED";
		case AMF_NOT_INITIALIZED:
			return "AMF_NOT_INITIALIZED";
		case AMF_INVALID_ARG:
			return "AMF_INVALID_ARG";
		case AMF_OUT_OF_MEMORY:
			return "AMF_OUT_OF_MEMORY";
		case AMF_ACCESS_DENIED:
			return "AMF_ACCESS_DENIED";
		case AMF_REPEAT:
			return "AMF_REPEAT";
		case AMF_INPUT_FULL:
			return "AMF_INPUT_FULL";
		default:
			return "AMF error";
		}
	}

	template < typename T >
	void SafeRelease( T *&p )
	{
		if ( p != nullptr )
		{
			p->Release();
			p = nullptr;
		}
	}

	// BGRA -> NV12 on the GPU. The matrix matches what NVENC produces for the same non-linear
	// sRGB frames: BT.709 with studio (limited) range.
	const char kConversionShader[] =
		"Texture2D sourceTexture : register(t0);\n"
		"SamplerState sourceSampler : register(s0);\n"
		"struct VSOut { float4 position : SV_Position; float2 uv : TEXCOORD0; };\n"
		"VSOut vs_main(uint id : SV_VertexID) {\n"
		"  float2 pos[3] = { float2(-1.0, -1.0), float2(-1.0, 3.0), float2(3.0, -1.0) };\n"
		"  float2 uv[3] = { float2(0.0, 1.0), float2(0.0, -1.0), float2(2.0, 1.0) };\n"
		"  VSOut o; o.position = float4(pos[id], 0.0, 1.0); o.uv = uv[id]; return o;\n"
		"}\n"
		"float3 ToYCbCr(float3 rgb) {\n"
		"  float y = dot(rgb, float3(0.2126, 0.7152, 0.0722));\n"
		"  float cb = (rgb.b - y) / 1.8556;\n"
		"  float cr = (rgb.r - y) / 1.5748;\n"
		"  return float3((16.0 + 219.0 * y) / 255.0, (128.0 + 224.0 * cb) / 255.0, (128.0 + 224.0 * cr) / 255.0);\n"
		"}\n"
		"float ps_y(VSOut input) : SV_Target {\n"
		"  return ToYCbCr(sourceTexture.Sample(sourceSampler, input.uv).rgb).x;\n"
		"}\n"
		"float2 ps_uv(VSOut input) : SV_Target {\n"
		"  uint width, height;\n"
		"  sourceTexture.GetDimensions(width, height);\n"
		"  float2 texel = float2(1.0 / float(width), 1.0 / float(height));\n"
		// The chroma target is half resolution, so input.uv already sits on the boundary between
		// two source texels; one sample per corner averages the 2x2 block the hardware wants.
		"  float3 rgb = sourceTexture.Sample(sourceSampler, input.uv + float2(-0.5, -0.5) * texel).rgb\n"
		"             + sourceTexture.Sample(sourceSampler, input.uv + float2( 0.5, -0.5) * texel).rgb\n"
		"             + sourceTexture.Sample(sourceSampler, input.uv + float2(-0.5,  0.5) * texel).rgb\n"
		"             + sourceTexture.Sample(sourceSampler, input.uv + float2( 0.5,  0.5) * texel).rgb;\n"
		"  float3 ycc = ToYCbCr(rgb * 0.25);\n"
		"  return float2(ycc.y, ycc.z);\n"
		"}\n";
}

struct FlowAmfEncoder::Impl
{
	AMFContext *context = nullptr;
	AMFComponent *encoder = nullptr;
	AMFSurface *surface = nullptr;

	ID3D11Device *device = nullptr;                // borrowed
	ID3D11DeviceContext *device_context = nullptr; // owns one reference (GetImmediateContext)
	ID3D11Texture2D *nv12_texture = nullptr;
	ID3D11RenderTargetView *luma_target = nullptr;
	ID3D11RenderTargetView *chroma_target = nullptr;
	ID3D11VertexShader *vertex_shader = nullptr;
	ID3D11PixelShader *luma_shader = nullptr;
	ID3D11PixelShader *chroma_shader = nullptr;
	ID3D11SamplerState *sampler = nullptr;

	uint32_t width = 0;
	uint32_t height = 0;
	uint32_t fps = 0;
	bool force_idr = false;
	// Frames submitted but not yet returned. AMF's output buffers do not carry our timestamps
	// reliably (FFmpeg keeps its own queue too), so packets are paired by submission order.
	std::deque< uint64_t > pending_pts;
	std::deque< std::pair< uint64_t, std::vector< uint8_t > > > ready_packets;
	uint64_t dropped_packets = 0;
	std::string last_error;
};

FlowAmfEncoder::FlowAmfEncoder() : impl_( std::make_unique< Impl >() )
{
}

FlowAmfEncoder::~FlowAmfEncoder()
{
	Shutdown();
}

void FlowAmfEncoder::SetError( const char *message )
{
	impl_->last_error = message;
	DriverLog( "Flow AMF: %s", message );
}

void FlowAmfEncoder::SetStatusError( const char *operation, int status )
{
	char buffer[ 256 ];
	std::snprintf( buffer, sizeof( buffer ), "%s failed status=0x%08x (%s)", operation, static_cast< unsigned int >( status ),
	               AmfStatusName( static_cast< AMF_RESULT >( status ) ) );
	SetError( buffer );
}

bool FlowAmfEncoder::CreateConversionResources()
{
	Impl &impl = *impl_;

	D3D11_TEXTURE2D_DESC desc{};
	desc.Width = impl.width;
	desc.Height = impl.height;
	desc.MipLevels = 1;
	desc.ArraySize = 1;
	desc.Format = DXGI_FORMAT_NV12;
	desc.SampleDesc.Count = 1;
	desc.Usage = D3D11_USAGE_DEFAULT;
	desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
	if ( FAILED( impl.device->CreateTexture2D( &desc, nullptr, &impl.nv12_texture ) ) )
	{
		SetError( "CreateTexture2D(NV12) failed" );
		return false;
	}

	// Plane render targets need D3D11.3: only D3D11_RENDER_TARGET_VIEW_DESC1 can name plane 1 of
	// an NV12 texture, the plain desc cannot address the chroma plane.
	ID3D11Device3 *device3 = nullptr;
	if ( FAILED( impl.device->QueryInterface( __uuidof( ID3D11Device3 ), reinterpret_cast< void ** >( &device3 ) ) ) || device3 == nullptr )
	{
		SetError( "D3D11.3 device unavailable (needed for NV12 plane render targets)" );
		return false;
	}

	ID3D11RenderTargetView1 *luma_target = nullptr;
	D3D11_RENDER_TARGET_VIEW_DESC1 luma_desc{};
	luma_desc.Format = DXGI_FORMAT_R8_UNORM;
	luma_desc.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
	luma_desc.Texture2D.MipSlice = 0;
	luma_desc.Texture2D.PlaneSlice = 0;
	HRESULT hr = device3->CreateRenderTargetView1( impl.nv12_texture, &luma_desc, &luma_target );
	impl.luma_target = luma_target;
	if ( FAILED( hr ) )
	{
		device3->Release();
		SetError( "CreateRenderTargetView1(NV12 luma) failed" );
		return false;
	}

	ID3D11RenderTargetView1 *chroma_target = nullptr;
	D3D11_RENDER_TARGET_VIEW_DESC1 chroma_desc{};
	chroma_desc.Format = DXGI_FORMAT_R8G8_UNORM;
	chroma_desc.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
	chroma_desc.Texture2D.MipSlice = 0;
	chroma_desc.Texture2D.PlaneSlice = 1;
	hr = device3->CreateRenderTargetView1( impl.nv12_texture, &chroma_desc, &chroma_target );
	impl.chroma_target = chroma_target;
	device3->Release();
	if ( FAILED( hr ) )
	{
		SetError( "CreateRenderTargetView1(NV12 chroma) failed" );
		return false;
	}

	const auto compile = [ & ]( const char *entry, const char *target, ID3DBlob **blob ) {
		ID3DBlob *error_blob = nullptr;
		const HRESULT hr = D3DCompile( kConversionShader, std::strlen( kConversionShader ), nullptr, nullptr, nullptr, entry, target, 0, 0, blob, &error_blob );
		if ( FAILED( hr ) )
		{
			char buffer[ 256 ];
			std::snprintf( buffer, sizeof( buffer ), "compiling %s failed: %s", entry,
			               error_blob != nullptr ? static_cast< const char * >( error_blob->GetBufferPointer() ) : "unknown error" );
			SetError( buffer );
		}
		if ( error_blob != nullptr )
		{
			error_blob->Release();
		}
		return SUCCEEDED( hr );
	};

	ID3DBlob *vs_blob = nullptr;
	ID3DBlob *y_blob = nullptr;
	ID3DBlob *uv_blob = nullptr;
	bool ok = compile( "vs_main", "vs_4_0", &vs_blob ) && compile( "ps_y", "ps_4_0", &y_blob ) && compile( "ps_uv", "ps_4_0", &uv_blob );
	if ( ok )
	{
		ok = SUCCEEDED( impl.device->CreateVertexShader( vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nullptr, &impl.vertex_shader ) ) &&
		     SUCCEEDED( impl.device->CreatePixelShader( y_blob->GetBufferPointer(), y_blob->GetBufferSize(), nullptr, &impl.luma_shader ) ) &&
		     SUCCEEDED( impl.device->CreatePixelShader( uv_blob->GetBufferPointer(), uv_blob->GetBufferSize(), nullptr, &impl.chroma_shader ) );
		if ( !ok )
		{
			SetError( "CreateShader failed" );
		}
	}
	if ( vs_blob != nullptr )
	{
		vs_blob->Release();
	}
	if ( y_blob != nullptr )
	{
		y_blob->Release();
	}
	if ( uv_blob != nullptr )
	{
		uv_blob->Release();
	}
	if ( !ok )
	{
		return false;
	}

	D3D11_SAMPLER_DESC sampler_desc{};
	sampler_desc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
	sampler_desc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
	sampler_desc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
	sampler_desc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
	sampler_desc.MaxLOD = D3D11_FLOAT32_MAX;
	if ( FAILED( impl.device->CreateSamplerState( &sampler_desc, &impl.sampler ) ) )
	{
		SetError( "CreateSamplerState failed" );
		return false;
	}
	return true;
}

void FlowAmfEncoder::ReleaseConversionResources()
{
	Impl &impl = *impl_;
	SafeRelease( impl.sampler );
	SafeRelease( impl.chroma_shader );
	SafeRelease( impl.luma_shader );
	SafeRelease( impl.vertex_shader );
	SafeRelease( impl.chroma_target );
	SafeRelease( impl.luma_target );
	SafeRelease( impl.nv12_texture );
	if ( impl.device_context != nullptr )
	{
		impl.device_context->Release();
		impl.device_context = nullptr;
	}
	impl.device = nullptr;
}

bool FlowAmfEncoder::RenderNv12( ID3D11Texture2D *texture )
{
	Impl &impl = *impl_;
	ID3D11ShaderResourceView *source_view = nullptr;
	if ( FAILED( impl.device->CreateShaderResourceView( texture, nullptr, &source_view ) ) )
	{
		SetError( "CreateShaderResourceView(source) failed" );
		return false;
	}

	ID3D11DeviceContext *dc = impl.device_context;
	dc->IASetInputLayout( nullptr );
	dc->IASetPrimitiveTopology( D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST );
	dc->VSSetShader( impl.vertex_shader, nullptr, 0 );
	dc->PSSetShaderResources( 0, 1, &source_view );
	dc->PSSetSamplers( 0, 1, &impl.sampler );

	D3D11_VIEWPORT viewport{};
	viewport.MinDepth = 0.0f;
	viewport.MaxDepth = 1.0f;

	// Luma: one sample per pixel.
	viewport.Width = static_cast< float >( impl.width );
	viewport.Height = static_cast< float >( impl.height );
	dc->RSSetViewports( 1, &viewport );
	dc->OMSetRenderTargets( 1, &impl.luma_target, nullptr );
	dc->PSSetShader( impl.luma_shader, nullptr, 0 );
	dc->Draw( 3, 0 );

	// Chroma: one sample per 2x2 block.
	viewport.Width = static_cast< float >( impl.width / 2 );
	viewport.Height = static_cast< float >( impl.height / 2 );
	dc->RSSetViewports( 1, &viewport );
	dc->OMSetRenderTargets( 1, &impl.chroma_target, nullptr );
	dc->PSSetShader( impl.chroma_shader, nullptr, 0 );
	dc->Draw( 3, 0 );

	ID3D11ShaderResourceView *null_view = nullptr;
	dc->PSSetShaderResources( 0, 1, &null_view );
	source_view->Release();
	return true;
}

bool FlowAmfEncoder::Initialize( ID3D11Device *device, uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate, uint32_t preset )
{
	Shutdown();
	if ( device == nullptr )
	{
		SetError( "Initialize called with null D3D11 device" );
		return false;
	}
	Impl &impl = *impl_;
	impl.device = device;
	impl.width = width;
	impl.height = height;
	impl.fps = fps;

	AmfRuntime &runtime = GetAmfRuntime();
	if ( !runtime.resolved )
	{
		SetError( runtime.error.c_str() );
		return false;
	}

	AMF_RESULT result = runtime.factory->CreateContext( &impl.context );
	if ( result != AMF_OK )
	{
		SetStatusError( "AMF CreateContext", result );
		Shutdown();
		return false;
	}
	result = impl.context->InitDX11( device );
	if ( result != AMF_OK )
	{
		SetStatusError( "AMF InitDX11", result );
		Shutdown();
		return false;
	}

	result = runtime.factory->CreateComponent( impl.context, AMFVideoEncoderVCE_AVC, &impl.encoder );
	if ( result != AMF_OK )
	{
		SetStatusError( "AMF CreateComponent(AVC)", result );
		Shutdown();
		return false;
	}

	// Static properties, must be set before Init(). The AMF quality preset is picked from the
	// same 1..7 knob NVENC uses so one setting covers both vendors.
	const amf_int64 quality = preset <= 2 ? static_cast< amf_int64 >( AMF_VIDEO_ENCODER_QUALITY_PRESET_SPEED )
	                                      : ( preset <= 5 ? static_cast< amf_int64 >( AMF_VIDEO_ENCODER_QUALITY_PRESET_BALANCED )
	                                                      : static_cast< amf_int64 >( AMF_VIDEO_ENCODER_QUALITY_PRESET_QUALITY ) );
	// The AMF C++ interface has a template SetProperty that builds the AMFVariant for us.
	const auto set_property = [ & ]( const wchar_t *name, const auto &value, const char *label, bool required ) {
		const AMF_RESULT result = impl.encoder->SetProperty( name, value );
		if ( result == AMF_OK )
		{
			return true;
		}
		char buffer[ 192 ];
		std::snprintf( buffer, sizeof( buffer ), "SetProperty(%s) failed status=0x%08x", label, static_cast< unsigned int >( result ) );
		if ( required )
		{
			SetError( buffer );
		}
		else
		{
			DriverLog( "Flow AMF: %s", buffer );
		}
		return !required;
	};

	// Ultra low latency: no B-frames, no lookahead, no frame skipping (a skipped frame would
	// break the 1:1 packet/timestamp pairing the caller relies on).
	const uint32_t vbv_bits = ( std::max )( bitrate / ( std::max )( fps, 1u ), 256u * 1024u );
	const bool configured =
	    set_property( AMF_VIDEO_ENCODER_USAGE, AMF_VIDEO_ENCODER_USAGE_ULTRA_LOW_LATENCY, "Usage", true ) &&
	    set_property( AMF_VIDEO_ENCODER_PROFILE, AMF_VIDEO_ENCODER_PROFILE_HIGH, "Profile", true ) &&
	    set_property( AMF_VIDEO_ENCODER_PROFILE_LEVEL, AMF_H264_LEVEL__5_1, "ProfileLevel", true ) &&
	    set_property( AMF_VIDEO_ENCODER_FRAMESIZE, AMFConstructSize( static_cast< amf_int32 >( width ), static_cast< amf_int32 >( height ) ),
	                  "FrameSize", true ) &&
	    set_property( AMF_VIDEO_ENCODER_FRAMERATE, AMFConstructRate( fps, 1 ), "FrameRate", true ) &&
	    set_property( AMF_VIDEO_ENCODER_RATE_CONTROL_METHOD, AMF_VIDEO_ENCODER_RATE_CONTROL_METHOD_CBR, "RateControlMethod", true ) &&
	    set_property( AMF_VIDEO_ENCODER_TARGET_BITRATE, static_cast< amf_int64 >( bitrate ), "TargetBitrate", true ) &&
	    set_property( AMF_VIDEO_ENCODER_PEAK_BITRATE, static_cast< amf_int64 >( bitrate ), "PeakBitrate", true ) &&
	    set_property( AMF_VIDEO_ENCODER_VBV_BUFFER_SIZE, static_cast< amf_int64 >( vbv_bits ), "VBVBufferSize", true ) &&
	    set_property( AMF_VIDEO_ENCODER_QUALITY_PRESET, quality, "QualityPreset", true ) &&
	    set_property( AMF_VIDEO_ENCODER_IDR_PERIOD, static_cast< amf_int64 >( fps ), "IDRPeriod", true ) &&
	    set_property( AMF_VIDEO_ENCODER_OUTPUT_MODE, AMF_VIDEO_ENCODER_OUTPUT_MODE_FRAME, "OutputMode", true );
	if ( !configured )
	{
		Shutdown();
		return false;
	}
	set_property( AMF_VIDEO_ENCODER_LOWLATENCY_MODE, true, "LowLatencyInternal", false );
	set_property( AMF_VIDEO_ENCODER_B_PIC_PATTERN, static_cast< amf_int64 >( 0 ), "BPicturesPattern", false );
	set_property( AMF_VIDEO_ENCODER_MAX_CONSECUTIVE_BPICTURES, static_cast< amf_int64 >( 0 ), "MaxConsecutiveBPictures", false );
	set_property( AMF_VIDEO_ENCODER_MAX_NUM_REFRAMES, static_cast< amf_int64 >( 1 ), "MaxNumRefFrames", false );
	set_property( AMF_VIDEO_ENCODER_PRE_ANALYSIS_ENABLE, false, "EnablePreAnalysis", false );
	set_property( AMF_VIDEO_ENCODER_ENFORCE_HRD, false, "EnforceHRD", false );
	set_property( AMF_VIDEO_ENCODER_FILLER_DATA_ENABLE, false, "FillerDataEnable", false );
	set_property( AMF_VIDEO_ENCODER_RATE_CONTROL_SKIP_FRAME_ENABLE, false, "RateControlSkipFrameEnable", false );
	set_property( AMF_VIDEO_ENCODER_ADAPTIVE_MINIGOP, false, "AdaptiveMiniGOP", false );
	// Repeat SPS/PPS so every IDR carries the headers FLOWH264 needs after a keyframe request.
	set_property( AMF_VIDEO_ENCODER_HEADER_INSERTION_SPACING, static_cast< amf_int64 >( 1 ), "HeaderInsertionSpacing", false );

	result = impl.encoder->Init( AMF_SURFACE_NV12, static_cast< amf_int32 >( width ), static_cast< amf_int32 >( height ) );
	if ( result != AMF_OK )
	{
		SetStatusError( "AMF Init", result );
		Shutdown();
		return false;
	}
	// Dynamic property: let QueryOutput wait for the bitstream instead of spinning.
	impl.encoder->SetProperty( AMF_VIDEO_ENCODER_QUERY_TIMEOUT, static_cast< amf_int64 >( kQueryTimeoutMs ) );

	device->GetImmediateContext( &impl.device_context );
	if ( impl.device_context == nullptr || !CreateConversionResources() )
	{
		Shutdown();
		return false;
	}

	// Wrap our NV12 texture: the hardware encoder reads it directly, no copy.
	result = impl.context->CreateSurfaceFromDX11Native( impl.nv12_texture, &impl.surface, nullptr );
	if ( result != AMF_OK )
	{
		SetStatusError( "AMF CreateSurfaceFromDX11Native", result );
		Shutdown();
		return false;
	}

	impl.last_error.clear();
	DriverLog( "Flow AMF initialized H264 %ux%u@%u bitrate=%u preset=%lld", width, height, fps, bitrate, static_cast< long long >( quality ) );
	return true;
}

bool FlowAmfEncoder::EncodeTexture( ID3D11Texture2D *texture, uint64_t pts_us, std::vector< uint8_t > &out_packet, uint64_t *out_pts_us,
                                    std::mutex *device_mutex )
{
	out_packet.clear();
	Impl &impl = *impl_;
	if ( impl.encoder == nullptr || impl.surface == nullptr || texture == nullptr )
	{
		return false;
	}

	{
		std::unique_lock< std::mutex > device_lock;
		if ( device_mutex != nullptr )
		{
			device_lock = std::unique_lock< std::mutex >( *device_mutex );
		}

		if ( !RenderNv12( texture ) )
		{
			return false;
		}
		impl.device_context->Flush(); // AMF must not read the texture before the conversion is done

		impl.surface->SetPts( static_cast< amf_pts >( pts_us ) * 10 ); // amf_pts counts 100 ns
		const amf_int64 forced = impl.force_idr ? AMF_VIDEO_ENCODER_PICTURE_TYPE_IDR : AMF_VIDEO_ENCODER_PICTURE_TYPE_NONE;
		impl.surface->SetProperty( AMF_VIDEO_ENCODER_FORCE_PICTURE_TYPE, forced );

		const AMF_RESULT submit = impl.encoder->SubmitInput( impl.surface );
		if ( submit == AMF_INPUT_FULL )
		{
			// The encoder has not consumed the previous frame yet: drop this one instead of
			// queueing it, so latency does not grow.
			if ( device_lock.owns_lock() )
			{
				device_lock.unlock();
			}
			return true;
		}
		if ( submit != AMF_OK && submit != AMF_NEED_MORE_INPUT )
		{
			SetStatusError( "AMF SubmitInput", submit );
			return false;
		}
		impl.force_idr = false;
		impl.pending_pts.push_back( pts_us );
		if ( device_lock.owns_lock() )
		{
			device_lock.unlock(); // the bitstream wait below needs no D3D access
		}
	}

	// Collect everything the encoder had ready. With AMD's one-frame delay this is zero on the
	// first call and one packet per call afterwards. The loop is bounded so a misbehaving runtime
	// can never spin the encode thread.
	for ( int drained = 0; drained < 8; ++drained )
	{
		AMFData *data = nullptr;
		impl.encoder->QueryOutput( &data );
		if ( data == nullptr )
		{
			break;
		}
		AMFBuffer *buffer = nullptr;
		data->QueryInterface( AMFBuffer::IID(), reinterpret_cast< void ** >( &buffer ) );
		data->Release();
		if ( buffer == nullptr )
		{
			break;
		}
		const amf_size size = buffer->GetSize();
		if ( size > 0 && buffer->GetNative() != nullptr )
		{
			const uint64_t packet_pts = impl.pending_pts.empty() ? 0 : impl.pending_pts.front();
			if ( !impl.pending_pts.empty() )
			{
				impl.pending_pts.pop_front();
			}
			const auto *bytes = static_cast< const uint8_t * >( buffer->GetNative() );
			impl.ready_packets.emplace_back( packet_pts, std::vector< uint8_t >( bytes, bytes + size ) );
		}
		buffer->Release();
	}

	while ( impl.ready_packets.size() > kMaxReadyPackets )
	{
		impl.ready_packets.pop_front();
		++impl.dropped_packets;
		if ( impl.dropped_packets == 1 )
		{
			DriverLog( "Flow AMF: encoder falling behind; dropping the oldest packet" );
		}
	}

	if ( !impl.ready_packets.empty() )
	{
		out_packet = std::move( impl.ready_packets.front().second );
		if ( out_pts_us != nullptr )
		{
			*out_pts_us = impl.ready_packets.front().first;
		}
		impl.ready_packets.pop_front();
	}
	return true;
}

void FlowAmfEncoder::RequestKeyframe()
{
	impl_->force_idr = true;
}

void FlowAmfEncoder::Shutdown()
{
	Impl &impl = *impl_;
	impl.pending_pts.clear();
	impl.ready_packets.clear();
	impl.force_idr = false;
	if ( impl.surface != nullptr )
	{
		impl.surface->Release();
		impl.surface = nullptr;
	}
	ReleaseConversionResources();
	if ( impl.encoder != nullptr )
	{
		impl.encoder->Release();
		impl.encoder = nullptr;
	}
	if ( impl.context != nullptr )
	{
		impl.context->Release();
		impl.context = nullptr;
	}
	// The AMF runtime itself stays loaded for the process (see GetAmfRuntime).
	impl.width = 0;
	impl.height = 0;
	impl.fps = 0;
}

const std::string &FlowAmfEncoder::LastError() const
{
	return impl_->last_error;
}

bool FlowAmfEncoder::IsInitialized() const
{
	return impl_->encoder != nullptr;
}

const char *FlowAmfEncoder::BackendName() const
{
	return "AMF";
}

#else // !_WIN32

struct FlowAmfEncoder::Impl
{
	std::string last_error;
};

FlowAmfEncoder::FlowAmfEncoder() : impl_( std::make_unique< Impl >() ) {}
FlowAmfEncoder::~FlowAmfEncoder() {}
void FlowAmfEncoder::SetError( const char *message ) { impl_->last_error = message; }
void FlowAmfEncoder::SetStatusError( const char *, int ) {}
bool FlowAmfEncoder::CreateConversionResources() { return false; }
bool FlowAmfEncoder::RenderNv12( ID3D11Texture2D * ) { return false; }
void FlowAmfEncoder::ReleaseConversionResources() {}
bool FlowAmfEncoder::Initialize( ID3D11Device *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t )
{
	SetError( "AMD AMF encoding is Windows-only" );
	return false;
}
bool FlowAmfEncoder::EncodeTexture( ID3D11Texture2D *, uint64_t, std::vector< uint8_t > &, uint64_t *, std::mutex * ) { return false; }
void FlowAmfEncoder::RequestKeyframe() {}
void FlowAmfEncoder::Shutdown() {}
const std::string &FlowAmfEncoder::LastError() const { return impl_->last_error; }
bool FlowAmfEncoder::IsInitialized() const { return false; }
const char *FlowAmfEncoder::BackendName() const { return "AMF"; }

#endif
