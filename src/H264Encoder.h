/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Hardware-accelerated H.264 encoder backed by VideoToolbox.

 * Produces an Annex-B byte stream (`00 00 00 01` start codes) which is what
 * the RFB "Open H.264 Encoding" and noVNC's WebCodecs decoder expect. SPS/PPS
 * are prepended to every IDR keyframe so a decoder that just joined the stream
 * can configure itself and start decoding from that single access unit.
 *
 * Keyframe policy (this is the part that makes noVNC happy):
 *  - the very first frame is forced to be an IDR keyframe,
 *  - an IDR is forced whenever -requestKeyframe is called,
 *  - an IDR is forced every `MaxKeyFrameInterval` frames otherwise.
 *
 * The session is configured for the H.264 Baseline profile with frame
 * reordering disabled, which guarantees frames arrive in decode order and are
 * decodable by browsers (no B-frames).
 */
@interface TVH264Encoder : NSObject

- (instancetype)initWithWidth:(int)width height:(int)height NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** Enqueue one BGRA pixel buffer. `forceKeyframe` requests an IDR for this frame. */
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer forceKeyframe:(BOOL)forceKeyframe;

/** Ask the encoder to emit an IDR on the next enqueued frame (e.g. a new client connected). */
- (void)requestKeyframe;

/** Invoked on an internal serial queue with the Annex-B data and its keyframe flag. */
@property(nonatomic, copy, nullable) void (^outputHandler)(NSData *annexBData, BOOL isKeyframe);

/** Stop the session and release hardware resources. Safe to call more than once. */
- (void)invalidate;

/** The coded dimensions this encoder was created with (read-only). */
@property(nonatomic, readonly) int width;
@property(nonatomic, readonly) int height;

@end

NS_ASSUME_NONNULL_END
