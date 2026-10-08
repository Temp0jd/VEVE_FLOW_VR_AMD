//============ Copyright (c) Valve Corporation, All rights reserved. ============
#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct ID3D11Device;
struct ID3D11Texture2D;

// Which GPU video encoder the driver and the dashboard helper use. The Flow only ever sees
// H.264, so both backends produce the same FLOWH264 stream; they differ in the PC-side encoder
// API: NVIDIA NVENC (nvEncodeAPI64.dll) on Nvidia GPUs, AMD AMF (amfrt64.dll) on Radeon.
enum class FlowVideoEncoderBackend
{
	Auto = 0,
	Nvenc,
	Amf,
};

// "auto" / "nvenc" / "amf" (case-insensitive); anything else is Auto.
FlowVideoEncoderBackend FlowVideoEncoderBackendFromString( const std::string &value );
const char *FlowVideoEncoderBackendName( FlowVideoEncoderBackend backend );

// Adapter vendor of a D3D11 device: decides which backend "auto" picks.
enum class FlowGpuVendor
{
	Unknown,
	Nvidia,
	Amd,
	Intel,
	Other,
};

FlowGpuVendor FlowGpuVendorOf( ID3D11Device *device );
// "NVIDIA GeForce RTX 4080" / "AMD Radeon RX 7900 XTX" / "unknown adapter", for the log.
std::string FlowGpuDescription( ID3D11Device *device );

// Which backend "auto" would choose for this device, ignoring whether the runtime DLL is
// actually installed. Used for logging and for the settings fallback.
FlowVideoEncoderBackend FlowPreferredVideoEncoderBackend( ID3D11Device *device );

// Encodes BGRA textures to H.264 Annex B. One call produces at most one packet: the caller hands
// a texture together with the timestamp of the frame it contains and gets back the bitstream the
// encoder has ready, plus the timestamp of the frame that bitstream actually holds. The two can
// differ: NVENC returns the packet for the texture it was just given, while AMD's encoder has one
// frame of pipeline delay, so a submitted frame's bitstream comes back one call later. Callers
// must stamp the packet with out_pts_us, and must skip sending when out_packet is empty.
class IFlowVideoEncoder
{
public:
	virtual ~IFlowVideoEncoder() = default;

	// preset: NVENC P1 (fastest) .. P7 (best); AMF maps the same number onto its speed ..
	// quality presets. Both run with ultra-low-latency tuning.
	virtual bool Initialize( ID3D11Device *device, uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate, uint32_t preset ) = 0;
	// device_mutex (optional) is held only while submitting work to the D3D device, not while
	// waiting for the bitstream, so a render thread sharing the device is never blocked on the
	// encoder. out_pts_us may be null. Returns false on error; an empty packet is not an error.
	virtual bool EncodeTexture( ID3D11Texture2D *texture, uint64_t pts_us, std::vector< uint8_t > &out_packet,
	                            uint64_t *out_pts_us, std::mutex *device_mutex = nullptr ) = 0;
	// Next submitted frame becomes an IDR with SPS/PPS, e.g. so a newly connected client can
	// start decoding.
	virtual void RequestKeyframe() = 0;
	virtual void Shutdown() = 0;

	virtual const std::string &LastError() const = 0;
	virtual bool IsInitialized() const = 0;
	virtual const char *BackendName() const = 0;
};

// Creates and initializes an encoder. With Auto, the backend preferred for the device is tried
// first and the other one is used if it fails to initialize (e.g. a Radeon with an Nvidia
// card that has no display attached, or the vendor's runtime DLL not being installed).
// Returns null on failure, with the reason in *error.
std::unique_ptr< IFlowVideoEncoder > FlowCreateInitializedVideoEncoder( FlowVideoEncoderBackend requested, ID3D11Device *device,
                                                                       uint32_t width, uint32_t height, uint32_t fps,
                                                                       uint32_t bitrate, uint32_t preset, std::string *error );
