//============ Copyright (c) Valve Corporation, All rights reserved. ============
#include "flow_video_encoder.h"

#include "driverlog.h"
#include "flow_amf_encoder.h"
#include "flow_nvenc_encoder.h"

#include <algorithm>
#include <cctype>
#include <cstdio>

#ifdef _WIN32
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#endif

namespace
{
	constexpr uint32_t kVendorNvidia = 0x10DE;
	constexpr uint32_t kVendorAmd = 0x1002;
	constexpr uint32_t kVendorAmdLegacy = 0x1022;
	constexpr uint32_t kVendorIntel = 0x8086;

#ifdef _WIN32
	// Adapter description of the device's adapter; false if it cannot be queried.
	bool ReadAdapterDesc( ID3D11Device *device, DXGI_ADAPTER_DESC1 *desc )
	{
		if ( device == nullptr )
		{
			return false;
		}
		IDXGIDevice *dxgi_device = nullptr;
		if ( FAILED( device->QueryInterface( __uuidof( IDXGIDevice ), reinterpret_cast< void ** >( &dxgi_device ) ) ) )
		{
			return false;
		}
		IDXGIAdapter *adapter = nullptr;
		const HRESULT hr = dxgi_device->GetAdapter( &adapter );
		dxgi_device->Release();
		if ( FAILED( hr ) || adapter == nullptr )
		{
			return false;
		}
		bool ok = false;
		IDXGIAdapter1 *adapter1 = nullptr;
		if ( SUCCEEDED( adapter->QueryInterface( __uuidof( IDXGIAdapter1 ), reinterpret_cast< void ** >( &adapter1 ) ) ) )
		{
			ok = SUCCEEDED( adapter1->GetDesc1( desc ) );
			adapter1->Release();
		}
		adapter->Release();
		return ok;
	}
#endif

	std::unique_ptr< IFlowVideoEncoder > CreateBackend( FlowVideoEncoderBackend backend )
	{
		switch ( backend )
		{
		case FlowVideoEncoderBackend::Nvenc:
			return std::make_unique< FlowNvencEncoder >();
		case FlowVideoEncoderBackend::Amf:
			return std::make_unique< FlowAmfEncoder >();
		default:
			return nullptr;
		}
	}
}

FlowVideoEncoderBackend FlowVideoEncoderBackendFromString( const std::string &value )
{
	std::string lower = value;
	std::transform( lower.begin(), lower.end(), lower.begin(),
	                []( unsigned char c ) { return static_cast< char >( std::tolower( c ) ); } );
	if ( lower == "nvenc" || lower == "nvidia" )
	{
		return FlowVideoEncoderBackend::Nvenc;
	}
	if ( lower == "amf" || lower == "amd" || lower == "radeon" )
	{
		return FlowVideoEncoderBackend::Amf;
	}
	return FlowVideoEncoderBackend::Auto;
}

const char *FlowVideoEncoderBackendName( FlowVideoEncoderBackend backend )
{
	switch ( backend )
	{
	case FlowVideoEncoderBackend::Nvenc:
		return "NVENC";
	case FlowVideoEncoderBackend::Amf:
		return "AMF";
	default:
		return "auto";
	}
}

FlowGpuVendor FlowGpuVendorOf( ID3D11Device *device )
{
#ifdef _WIN32
	DXGI_ADAPTER_DESC1 desc{};
	if ( !ReadAdapterDesc( device, &desc ) )
	{
		return FlowGpuVendor::Unknown;
	}
	switch ( desc.VendorId )
	{
	case kVendorNvidia:
		return FlowGpuVendor::Nvidia;
	case kVendorAmd:
	case kVendorAmdLegacy:
		return FlowGpuVendor::Amd;
	case kVendorIntel:
		return FlowGpuVendor::Intel;
	default:
		return FlowGpuVendor::Other;
	}
#else
	(void)device;
	return FlowGpuVendor::Unknown;
#endif
}

std::string FlowGpuDescription( ID3D11Device *device )
{
#ifdef _WIN32
	DXGI_ADAPTER_DESC1 desc{};
	if ( !ReadAdapterDesc( device, &desc ) )
	{
		return "unknown adapter";
	}
	const int bytes = WideCharToMultiByte( CP_UTF8, 0, desc.Description, -1, nullptr, 0, nullptr, nullptr );
	if ( bytes <= 1 )
	{
		return "unknown adapter";
	}
	std::string text( static_cast< size_t >( bytes - 1 ), '\0' );
	WideCharToMultiByte( CP_UTF8, 0, desc.Description, -1, text.data(), bytes, nullptr, nullptr );
	char vendor[ 64 ];
	std::snprintf( vendor, sizeof( vendor ), " (vendor 0x%04x)", desc.VendorId );
	return text + vendor;
#else
	(void)device;
	return "unknown adapter";
#endif
}

FlowVideoEncoderBackend FlowPreferredVideoEncoderBackend( ID3D11Device *device )
{
	// AMD GPUs have no NVENC, Nvidia GPUs have no AMF; everything else (Intel, WARP, a virtual
	// adapter) falls back to NVENC so a machine that worked before keeps its old behaviour.
	return FlowGpuVendorOf( device ) == FlowGpuVendor::Amd ? FlowVideoEncoderBackend::Amf : FlowVideoEncoderBackend::Nvenc;
}

std::unique_ptr< IFlowVideoEncoder > FlowCreateInitializedVideoEncoder( FlowVideoEncoderBackend requested, ID3D11Device *device,
                                                                       uint32_t width, uint32_t height, uint32_t fps,
                                                                       uint32_t bitrate, uint32_t preset, std::string *error )
{
	FlowVideoEncoderBackend first = requested;
	if ( first == FlowVideoEncoderBackend::Auto )
	{
		first = FlowPreferredVideoEncoderBackend( device );
	}

	const auto try_backend = [ & ]( FlowVideoEncoderBackend backend, std::string *why ) -> std::unique_ptr< IFlowVideoEncoder > {
		std::unique_ptr< IFlowVideoEncoder > encoder = CreateBackend( backend );
		if ( encoder == nullptr )
		{
			if ( why != nullptr )
			{
				*why = "unsupported backend";
			}
			return nullptr;
		}
		if ( encoder->Initialize( device, width, height, fps, bitrate, preset ) )
		{
			return encoder;
		}
		if ( why != nullptr )
		{
			*why = encoder->LastError();
		}
		return nullptr;
	};

	std::string first_error;
	if ( std::unique_ptr< IFlowVideoEncoder > encoder = try_backend( first, &first_error ) )
	{
		return encoder;
	}

	if ( requested == FlowVideoEncoderBackend::Auto )
	{
		const FlowVideoEncoderBackend second = first == FlowVideoEncoderBackend::Nvenc ? FlowVideoEncoderBackend::Amf : FlowVideoEncoderBackend::Nvenc;
		std::string second_error;
		if ( std::unique_ptr< IFlowVideoEncoder > encoder = try_backend( second, &second_error ) )
		{
			DriverLog( "Flow encoder: %s unavailable (%s); falling back to %s", FlowVideoEncoderBackendName( first ), first_error.c_str(),
			           FlowVideoEncoderBackendName( second ) );
			return encoder;
		}
		if ( error != nullptr )
		{
			*error = std::string( FlowVideoEncoderBackendName( first ) ) + ": " + first_error + "; " + FlowVideoEncoderBackendName( second ) + ": " +
			         second_error;
		}
		DriverLog( "Flow encoder: no usable GPU encoder (%s)", first_error.c_str() );
		return nullptr;
	}

	if ( error != nullptr )
	{
		*error = std::string( FlowVideoEncoderBackendName( first ) ) + ": " + first_error;
	}
	DriverLog( "Flow encoder: %s failed: %s", FlowVideoEncoderBackendName( first ), first_error.c_str() );
	return nullptr;
}
