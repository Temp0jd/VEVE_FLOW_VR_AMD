//============ Copyright (c) Valve Corporation, All rights reserved. ============
#pragma once

#include "flow_video_encoder.h"

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

struct ID3D11Device;
struct ID3D11Texture2D;

// H.264 encoder on NVIDIA GPUs through NVENC (nvEncodeAPI64.dll, part of the GeForce driver).
// Takes the caller's BGRA texture directly: NVENC accepts ARGB input surfaces.
class FlowNvencEncoder : public IFlowVideoEncoder
{
public:
	FlowNvencEncoder();
	~FlowNvencEncoder() override;

	// preset: NVENC P1 (fastest) .. P7 (best quality); always with ultra-low-latency tuning.
	bool Initialize( ID3D11Device *device, uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate, uint32_t preset ) override;
	// device_mutex (optional) is held only while submitting work to the D3D device, not while
	// waiting for the bitstream, so a render thread sharing the device is never blocked on NVENC.
	// NVENC is synchronous, so the returned packet always holds the frame that was just handed in
	// and out_pts_us is that same timestamp.
	bool EncodeTexture( ID3D11Texture2D *texture, uint64_t pts_us, std::vector< uint8_t > &out_packet, uint64_t *out_pts_us,
	                    std::mutex *device_mutex = nullptr ) override;
	// Next frame becomes an IDR with SPS/PPS, e.g. so a newly connected client can start decoding.
	void RequestKeyframe() override;
	void Shutdown() override;

	const std::string &LastError() const override;
	bool IsInitialized() const override;
	const char *BackendName() const override { return "NVENC"; }

private:
	bool LoadApi();
	void SetError( const char *message );
	void SetStatusError( const char *operation, int status );
	void UnregisterInput();

	void *module_ = nullptr;
	void *encoder_ = nullptr;
	void *bitstream_buffer_ = nullptr;
	// Input textures registered with NVENC; callers rotate through a few, so keep them all.
	std::vector< std::pair< ID3D11Texture2D *, void * > > registrations_;

	uint32_t width_ = 0;
	uint32_t height_ = 0;
	uint32_t fps_ = 0;
	uint32_t api_version_ = 0;
	uint32_t frame_index_ = 0;
	bool sent_headers_ = false;
	std::string last_error_;
	std::vector< uint8_t > packet_buffer_;

	struct Api;
	Api *api_ = nullptr;
};
