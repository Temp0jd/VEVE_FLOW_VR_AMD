//============ Copyright (c) Valve Corporation, All rights reserved. ============
#include "flow_amf_encoder.h"

#include "driverlog.h"

#include <algorithm>
#include <chrono>
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

	// The NAL types present in an Annex-B buffer, and whether SPS (7) and PPS (8) are among them.
	// This mirrors the rule the driver applies in EnsureH264StreamHeader, which needs both in one
	// packet before it can send the FLOWH264 stream header the Flow's decoder is configured from -
	// without that header the headset has nothing to decode and shows an uninitialised surface.
	struct NalSummary
	{
		bool sps = false;
		bool pps = false;
		std::string types;
	};

	NalSummary SummarizeNals( const uint8_t *data, size_t size )
	{
		NalSummary summary;
		size_t i = 0;
		while ( i + 3 < size )
		{
			size_t header = 0;
			if ( data[ i ] == 0 && data[ i + 1 ] == 0 && data[ i + 2 ] == 1 )
			{
				header = i + 3;
			}
			else if ( i + 4 < size && data[ i ] == 0 && data[ i + 1 ] == 0 && data[ i + 2 ] == 0 && data[ i + 3 ] == 1 )
			{
				header = i + 4;
			}
			if ( header == 0 || header >= size )
			{
				++i;
				continue;
			}
			const int type = data[ header ] & 0x1f;
			if ( type >= 1 && type <= 12 )
			{
				if ( type == 7 )
				{
					summary.sps = true;
				}
				if ( type == 8 )
				{
					summary.pps = true;
				}
				if ( !summary.types.empty() )
				{
					summary.types += ",";
				}
				summary.types += std::to_string( type );
			}
			i = header + 1;
		}
		return summary;
	}

	// Lowest H.264 level that can carry this stream. The limits are macroblocks per second and per
	// frame, and the obvious 5.1 is not enough for 3200x1600 at 75 fps: 20,000 macroblocks a frame is
	// 1,500,000 a second, while level 5.1 allows 983,040 and level 5.2 allows 2,073,600 - which is
	// also exactly what the Flow decoder declares as its maximum. The driver's NVENC backend lets
	// NVENC pick the level; this keeps the AMF backend in the same place instead of declaring a
	// level the stream cannot fit into.
	amf_int64 H264LevelForStream( uint32_t width, uint32_t height, uint32_t fps )
	{
		const int64_t macroblocks = static_cast< int64_t >( ( width + 15 ) / 16 ) * static_cast< int64_t >( ( height + 15 ) / 16 );
		const int64_t per_second = macroblocks * ( fps > 0 ? fps : 1 );
		if ( per_second <= 983040 && macroblocks <= 36864 )
		{
			return AMF_H264_LEVEL__5_1;
		}
		if ( per_second <= 2073600 && macroblocks <= 36864 )
		{
			return AMF_H264_LEVEL__5_2;
		}
		if ( per_second <= 4177920 && macroblocks <= 139264 )
		{
			return AMF_H264_LEVEL__6;
		}
		return AMF_H264_LEVEL__6_2;
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
	// Signals when the GPU has finished converting into nv12_texture. ID3D11DeviceContext::Flush()
	// only hands the command buffer to the GPU, it does not wait for it to execute, and AMF's
	// hardware encoder reads the surface from a different engine with no cross-engine sync - so
	// without waiting on this the encoder reads the untouched (black) surface every frame.
	ID3D11Query *conversion_done = nullptr;
	bool conversion_wait_reported = false;
	// The D3D11 texture behind the AMF surface the encoder reads (borrowed from its plane), and its
	// DXGI format: the per-frame copy is only possible when that layout matches the converted NV12.
	ID3D11Texture2D *surface_texture = nullptr;
	DXGI_FORMAT surface_format = DXGI_FORMAT_UNKNOWN;
	bool surface_copy_logged = false;
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
	// SPS/PPS in Annex B form, taken from AMF's read-only ExtraData property after Init (AMF does
	// not put them in the stream itself). See Initialize.
	std::vector< uint8_t > parameter_sets;
	uint32_t packets_checked = 0;
	bool parameter_sets_reported = false;
	bool parameter_sets_prepended = false;
	// One-off check that the BGRA -> NV12 conversion really wrote an image (see RenderNv12).
	bool conversion_checked = false;
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
	// No D3D11_RESOURCE_MISC_SHARED: AMF's CreateSurfaceFromDX11Native is handed this texture
	// pointer and wraps it in-process, so no sharing is involved (FFmpeg's D3D11 hwcontext makes
	// that flag opt-in too).
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

	// Completion marker for the conversion, waited on before every submit (see EncodeTexture).
	D3D11_QUERY_DESC query_desc{};
	query_desc.Query = D3D11_QUERY_EVENT;
	if ( FAILED( impl.device->CreateQuery( &query_desc, &impl.conversion_done ) ) )
	{
		impl.conversion_done = nullptr; // not fatal: EncodeTexture falls back to a plain Flush
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
	SafeRelease( impl.conversion_done );
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
	// This runs on the same immediate context as the driver's own scaling work, so the state must be
	// set explicitly rather than inherited: a scissor-enabled rasterizer state with the default
	// (empty) scissor rect clips the whole draw away and leaves the plane zeroed, and an inherited
	// alpha-blending state can discard the write the same way - both look exactly like "the encoder
	// is being fed a black image".
	dc->RSSetState( nullptr );
	dc->OMSetBlendState( nullptr, nullptr, 0xffffffff );
	dc->OMSetDepthStencilState( nullptr, 0 );
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
	// Leave no render target of ours bound for the render thread to inherit.
	dc->OMSetRenderTargets( 0, nullptr, nullptr );
	source_view->Release();

	// Once, read the luma plane back and report what the conversion actually produced. This is the
	// difference between "the draw wrote nothing" and "AMF read an empty surface", which is
	// otherwise invisible: either way the encoder happily encodes a black frame.
	if ( !impl.conversion_checked )
	{
		impl.conversion_checked = true;
		D3D11_TEXTURE2D_DESC staging_desc{};
		staging_desc.Width = impl.width;
		staging_desc.Height = impl.height;
		staging_desc.MipLevels = 1;
		staging_desc.ArraySize = 1;
		staging_desc.Format = DXGI_FORMAT_NV12;
		staging_desc.SampleDesc.Count = 1;
		staging_desc.Usage = D3D11_USAGE_STAGING;
		staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
		ID3D11Texture2D *snapshot = nullptr;
		if ( SUCCEEDED( impl.device->CreateTexture2D( &staging_desc, nullptr, &snapshot ) ) && snapshot != nullptr )
		{
			dc->CopyResource( snapshot, impl.nv12_texture );
			D3D11_MAPPED_SUBRESOURCE mapped{};
			if ( SUCCEEDED( dc->Map( snapshot, 0, D3D11_MAP_READ, 0, &mapped ) ) )
			{
				const auto *rows = static_cast< const uint8_t * >( mapped.pData );
				uint32_t min_value = 255;
				uint32_t max_value = 0;
				uint64_t total = 0;
				for ( uint32_t y = 0; y < impl.height; ++y )
				{
					const uint8_t *row = rows + static_cast< size_t >( y ) * mapped.RowPitch;
					for ( uint32_t x = 0; x < impl.width; ++x )
					{
						const uint32_t value = row[ x ];
						min_value = value < min_value ? value : min_value;
						max_value = value > max_value ? value : max_value;
						total += value;
					}
				}
				const uint64_t samples = static_cast< uint64_t >( impl.width ) * impl.height;
				DriverLog( "Flow AMF: converted NV12 luma min=%u max=%u avg=%llu (%ux%u)", min_value, max_value,
				           static_cast< unsigned long long >( total / ( samples > 0 ? samples : 1 ) ), impl.width, impl.height );
				dc->Unmap( snapshot, 0 );
			}
			snapshot->Release();
		}
	}
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
	// AMF's D3D11 context has two capability levels and the default is the lower one
	// (AMF_DX11_0). FFmpeg's AMF integration asks for AMF_DX11_1, which is what makes the newer
	// D3D11 interop paths - including NV12 textures - available, so ask for that and fall back.
	AMF_DX_VERSION dx_version = AMF_DX11_1;
	result = impl.context->InitDX11( device, dx_version );
	if ( result != AMF_OK )
	{
		dx_version = AMF_DX11_0;
		result = impl.context->InitDX11( device, dx_version );
	}
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
	const amf_int64 level = H264LevelForStream( width, height, fps );
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
	    set_property( AMF_VIDEO_ENCODER_PROFILE_LEVEL, level, "ProfileLevel", true ) &&
	    // AMF leaves both of these off by default, which produces a stream with slices but no
	    // parameter sets at all: nothing can decode it, and the driver cannot build the FLOWH264
	    // stream header (it needs SPS and PPS in the same packet). They are mandatory here because a
	    // stream without them is not usable.
	    set_property( AMF_VIDEO_ENCODER_INSERT_SPS, true, "InsertSPS", true ) &&
	    set_property( AMF_VIDEO_ENCODER_INSERT_PPS, true, "InsertPPS", true ) &&
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
	// SPS/PPS: AMF leaves them out of the stream (AMF_VIDEO_ENCODER_INSERT_SPS/PPS default to false)
	// and exposes them through the read-only ExtraData property instead. FFmpeg's AMF encoder reads
	// exactly this property straight after Init() and treats the buffer as extradata; the same
	// buffer is what FLOWH264 needs, because the driver scans a packet for SPS *and* PPS to build
	// the stream header the Flow's decoder is configured from. The interface is released by hand,
	// as in FFmpeg's C code, so the value is read into a plain AMFVariantStruct.
	AMFVariantStruct variant = {};
	if ( impl.encoder->GetProperty( AMF_VIDEO_ENCODER_EXTRADATA, &variant ) == AMF_OK &&
	     variant.type == AMF_VARIANT_INTERFACE && variant.pInterface != nullptr )
	{
		AMFBuffer *buffer = nullptr;
		if ( variant.pInterface->QueryInterface( AMFBuffer::IID(), reinterpret_cast< void ** >( &buffer ) ) == AMF_OK &&
		     buffer != nullptr && buffer->GetSize() > 0 && buffer->GetNative() != nullptr )
		{
			const auto *bytes = static_cast< const uint8_t * >( buffer->GetNative() );
			impl.parameter_sets.assign( bytes, bytes + buffer->GetSize() );
			buffer->Release();
		}
		variant.pInterface->Release();
	}

	// Dynamic property: let QueryOutput wait for the bitstream instead of spinning.
	impl.encoder->SetProperty( AMF_VIDEO_ENCODER_QUERY_TIMEOUT, static_cast< amf_int64 >( kQueryTimeoutMs ) );

	device->GetImmediateContext( &impl.device_context );
	if ( impl.device_context == nullptr || !CreateConversionResources() )
	{
		Shutdown();
		return false;
	}

	// The encoder's input surface: AMF allocates it and EncodeTexture copies the converted frame in.
	// Wrapping the texture this backend renders into produced a surface the encoder read as empty;
	// the conversion itself is provably correct, because reading that very texture back shows a full
	// 16..235 range while the encoded frames are black. So hand the encoder a surface it owns.
	result = impl.context->AllocSurface( AMF_MEMORY_DX11, AMF_SURFACE_NV12, static_cast< amf_int32 >( width ),
	                                     static_cast< amf_int32 >( height ), &impl.surface );
	if ( result != AMF_OK )
	{
		SetStatusError( "AMF AllocSurface(NV12, DX11)", result );
		Shutdown();
		return false;
	}

	// The texture behind that surface, and its DXGI format: the copy is only possible when the
	// layouts match, and the format is what tells us whether they do.
	if ( impl.surface->GetPlanesCount() > 0 )
	{
		AMFPlane *plane = impl.surface->GetPlaneAt( 0 );
		if ( plane != nullptr )
		{
			impl.surface_texture = static_cast< ID3D11Texture2D * >( plane->GetNative() );
		}
	}
	if ( impl.surface_texture != nullptr )
	{
		D3D11_TEXTURE2D_DESC surface_desc{};
		impl.surface_texture->GetDesc( &surface_desc );
		impl.surface_format = surface_desc.Format;
		DriverLog( "Flow AMF: encoder surface %ux%u dxgi_format=%u (converted NV12 is %u)", surface_desc.Width,
		           surface_desc.Height, static_cast< unsigned >( surface_desc.Format ),
		           static_cast< unsigned >( DXGI_FORMAT_NV12 ) );
	}
	else
	{
		DriverLog( "Flow AMF: encoder surface exposes no native DX11 texture; cannot copy into it" );
	}

	impl.last_error.clear();
	DriverLog( "Flow AMF initialized H264 %ux%u@%u bitrate=%u preset=%lld level=%lld extra_data=%zu bytes dx=%lld", width, height,
	           fps, bitrate, static_cast< long long >( quality ), static_cast< long long >( level ),
	           impl.parameter_sets.size(), static_cast< long long >( dx_version ) );
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

		// Copy the converted frame into the encoder's own surface (see Initialize for why the surface
		// is not the texture this backend renders into).
		if ( impl.surface_texture != nullptr && impl.surface_format == DXGI_FORMAT_NV12 )
		{
			impl.device_context->CopyResource( impl.surface_texture, impl.nv12_texture );
			if ( !impl.surface_copy_logged )
			{
				impl.surface_copy_logged = true;
				DriverLog( "Flow AMF: copying the converted NV12 into the AMF surface every frame" );
			}
		}
		else if ( !impl.surface_copy_logged )
		{
			impl.surface_copy_logged = true;
			DriverLog( "Flow AMF: encoder surface is not DXGI_FORMAT_NV12 (%u), so no copy happens and the encoder reads an empty surface",
			           static_cast< unsigned >( impl.surface_format ) );
		}

		// Wait for the conversion to actually finish on the GPU before handing the surface to AMF.
		// Flush() alone is not enough: it queues the commands but returns immediately, and the encoder
		// reads the surface from its own engine, so it would otherwise encode the untouched surface -
		// which is exactly what "the stream is black although the conversion wrote a proper image"
		// looks like. Bounded, so a stuck GPU cannot hang the encode thread.
		if ( impl.conversion_done != nullptr )
		{
			impl.device_context->End( impl.conversion_done );
			impl.device_context->Flush();
			const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( 50 );
			HRESULT ready = S_FALSE;
			while ( ( ready = impl.device_context->GetData( impl.conversion_done, nullptr, 0, 0 ) ) == S_FALSE &&
			        std::chrono::steady_clock::now() < deadline )
			{
				Sleep( 0 );
			}
			if ( ready == S_FALSE && !impl.conversion_wait_reported )
			{
				impl.conversion_wait_reported = true;
				DriverLog( "Flow AMF: the NV12 conversion and copy did not finish within 50 ms; the encoder may read a stale surface" );
			}
		}
		else
		{
			impl.device_context->Flush();
		}

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

	while ( impl.ready_packets.size() > kMaxReadyPackets )	{
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

		// The driver builds the FLOWH264 stream header from the first packet that carries both SPS
		// and PPS (EnsureH264StreamHeader), and the Flow's decoder is configured from that header.
		// AMF exposes the parameter sets through ExtraData instead of the stream, so make the packet
		// look like the NVENC backend's output - parameter sets ahead of the frame - whenever the
		// encoder's own output does not already contain them. Only the driver's NAL scan and the
		// optional stream dump see this: SendH264Packet forwards just the VCL NALs.
		if ( !impl.parameter_sets.empty() )
		{
			const NalSummary nals = SummarizeNals( out_packet.data(), out_packet.size() );
			if ( !( nals.sps && nals.pps ) )
			{
				out_packet.insert( out_packet.begin(), impl.parameter_sets.begin(), impl.parameter_sets.end() );
				if ( !impl.parameter_sets_prepended )
				{
					impl.parameter_sets_prepended = true;
					DriverLog( "Flow AMF: prepended %zu bytes of SPS/PPS from ExtraData (encoder nal types %s)",
					           impl.parameter_sets.size(), nals.types.c_str() );
				}
			}
		}

		// Report once whether the packets really do carry the parameter sets the Flow needs.
		if ( !impl.parameter_sets_reported )
		{
			++impl.packets_checked;
			const NalSummary nals = SummarizeNals( out_packet.data(), out_packet.size() );
			if ( nals.sps && nals.pps )
			{
				impl.parameter_sets_reported = true;
				DriverLog( "Flow AMF: outgoing packets carry SPS and PPS (nal types %s)", nals.types.c_str() );
			}
			else if ( impl.packets_checked >= 150 ) // ~2 s at 75 fps
			{
				impl.parameter_sets_reported = true;
				DriverLog( "Flow AMF: no SPS/PPS in %u packets (nal types %s, extra data %zu bytes) - the Flow cannot decode this stream",
				           impl.packets_checked, nals.types.c_str(), impl.parameter_sets.size() );
			}
		}
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
