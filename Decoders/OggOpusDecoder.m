/*
 *  Copyright (C) 2024 Stephen F. Booth <me@sbooth.org>
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "OggOpusDecoder.h"
#import "CircularBuffer.h"

@implementation OggOpusDecoder

- (id) initWithFilename:(NSString *)filename
{
	if((self = [super initWithFilename:filename])) {
		int error;
		_of = op_open_file([[self filename] fileSystemRepresentation], &error);
		NSAssert1(NULL != _of, @"Unable to open the input file (%@).", @(error).stringValue);

		// Setup input format descriptor
		_pcmFormat.mFormatID			= kAudioFormatLinearPCM;

		_pcmFormat.mFormatFlags			= kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked;
		_pcmFormat.mSampleRate			= 48000;
		_pcmFormat.mChannelsPerFrame	= op_channel_count(_of, -1);
		_pcmFormat.mBitsPerChannel		= 16;

		_pcmFormat.mBytesPerPacket		= (_pcmFormat.mBitsPerChannel / 8) * _pcmFormat.mChannelsPerFrame;
		_pcmFormat.mFramesPerPacket		= 1;
		_pcmFormat.mBytesPerFrame		= _pcmFormat.mBytesPerPacket * _pcmFormat.mFramesPerPacket;
	}

	return self;
}

- (void) dealloc
{
	op_free(_of);
	[super dealloc];
}

- (NSString *)		sourceFormatDescription			{ return [NSString stringWithFormat:@"Ogg (Opus, %u channels, %u Hz)", [self pcmFormat].mChannelsPerFrame, (unsigned)[self pcmFormat].mSampleRate]; }

- (SInt64)			totalFrames						{ return op_pcm_total(_of, -1); }

- (BOOL)			supportsSeeking					{ return op_seekable(_of); }

- (SInt64) seekToFrame:(SInt64)frame
{
	if(op_pcm_seek(_of, frame)) {
		[[self pcmBuffer] reset];
		_currentFrame = frame;
	}

	return [self currentFrame];
}

- (void) fillPCMBuffer
{
	CircularBuffer*	buffer 			= [self pcmBuffer];
	void* 			rawBuffer		= [buffer exposeBufferForWriting];
	NSUInteger 		availableSpace	= [buffer freeSpaceAvailable];
	UInt32 			bytesPerFrame	= _pcmFormat.mBytesPerFrame;

	NSUInteger	totalBytes		= 0;
	int		currentSection		= 0;

	for(;;) {
		int16_t* sampleBuffer	= rawBuffer + totalBytes;
		int framesToRead		= (int)((availableSpace - totalBytes)/bytesPerFrame);

		int bytesRead	= bytesPerFrame*op_read(_of, sampleBuffer, framesToRead, &currentSection);
		NSAssert(0 <= bytesRead, @"Ogg Opus decode error.");

#if(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__)
		int samplesRead = bytesRead / 2;
		for(int sample = 0; sample < samplesRead; sample++) {
			sampleBuffer[sample] = OSSwapHostToBigInt16(sampleBuffer[sample]);
		}
#endif

		totalBytes += bytesRead;
		if((0 == bytesRead) || (totalBytes >= availableSpace)) {
			break;
		}
	}

	[buffer wroteBytes:totalBytes];
}

@end

