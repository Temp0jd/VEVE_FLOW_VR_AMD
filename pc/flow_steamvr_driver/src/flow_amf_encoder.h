//============ Copyright (c) Valve Corporation, All rights reserved. ============
#pragma once

#include "flow_video_encoder.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct ID3D11Device;
struct ID3D11Texture2D;

// H.264 encoder on AMD GPUs through AMF. amfrt64.dll comes with the Radeon driver, so nothing
// extra needs to be installed. The AMF hardware encoder takes NV12 natively, while the driver
// and the helper hand it BGRA, so every frame is converted on the GPU (a BT.709 limited-range
// full-screen pass) into an NV12 texture that is wrapped as an AMF surface.
//
// AMD's encoder has one frame of pipeline delay (a hardware property, see AMF issue #205), so
// the packet returned by EncodeTexture holds the *previous* call's frame and its timestamp is
// reported through out_pts_us. The first call after Initialize/RequestKeyframe returns no packet.
class FlowAmfEncoder : public IFlowVideoEncoder
{
public:
	FlowAmfEncoder();
	~FlowAmfEncoder() override;

	bool Initialize( ID3D11Device *device, uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate, uint32_t preset ) override;
	bool EncodeTexture( ID3D11Texture2D *texture, uint64_t pts_us, std::vector< uint8_t > &out_packet, uint64_t *out_pts_us,
	                    std::mutex *device_mutex = nullptr ) override;
	void RequestKeyframe() override;
	void Shutdown() override;

	const std::string &LastError() const override;
	bool IsInitialized() const override;
	const char *BackendName() const override;

private:
	void SetError( const char *message );
	void SetStatusError( const char *operation, int status );
	bool CreateConversionResources();
	bool RenderNv12( ID3D11Texture2D *texture );
	void ReleaseConversionResources();

	struct Impl;
	std::unique_ptr< Impl > impl_;
};
