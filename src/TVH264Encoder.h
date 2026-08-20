#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TVH264EncoderOutputBlock)(NSData *naluData, BOOL isKeyFrame);

@interface TVH264Encoder : NSObject

@property (nonatomic, copy) TVH264EncoderOutputBlock outputBlock;

- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
              orientation:(int)rotationQuad
                    scale:(CGFloat)scale;

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
