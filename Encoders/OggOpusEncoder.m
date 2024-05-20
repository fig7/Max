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

#import "OggOpusEncoder.h"

#include <opus/opusenc.h>

#include <CoreAudio/CoreAudioTypes.h>
#include <AudioToolbox/AudioFormat.h>
#include <AudioToolbox/AudioConverter.h>
#include <AudioToolbox/AudioFile.h>
#include <AudioToolbox/ExtendedAudioFile.h>

#import "Decoder.h"
#import "RegionDecoder.h"

#import "StopException.h"

#import "UtilityFunctions.h"

// My (semi-arbitrary) list of supported vorbis bitrates
static int sOpusBitrates [12] = { 48, 64, 96, 128, 144, 160, 176, 192, 208, 224, 240, 256 };

@interface OggOpusEncoder (Private)
- (void)	parseSettings;
@end

@implementation OggOpusEncoder

- (oneway void) encodeToFile:(NSString *) filename
{
	NSDate						*startTime							= [NSDate date];
	opus_int16					*buffer;

	int8_t						*buffer8							= NULL;
	int16_t						*buffer16							= NULL;
	int32_t						*buffer32							= NULL;
	unsigned					wideSample;
	unsigned					sample, channel;
	
	opus_int16					constructedSample;

	BOOL						eos									= NO;

	AudioBufferList				bufferList;
	ssize_t						bufferLen							= 0;
	UInt32						bufferByteSize						= 0;
	SInt64						totalFrames, framesToRead;
	UInt32						frameCount;
	
	unsigned long				iterations							= 0;
	
	double						percentComplete;
	NSTimeInterval				interval;
	unsigned					secondsRemaining;

	opus_int32 sampleRate;
	int numChannels;

	OggOpusComments* comments;
	OggOpusEnc* enc;

	@try {
		bufferList.mBuffers[0].mData = NULL;

		// Parse the encoder settings
		[self parseSettings];

		// Tell our owner we are starting
		[[self delegate] setStartTime:startTime];	
		[[self delegate] setStarted:YES];
		
		// Setup the decoder
		id <DecoderMethods> decoder = nil;
		NSString *sourceFilename = [[[self delegate] taskInfo] inputFilenameAtInputFileIndex];
		
		// Create the appropriate kind of decoder
		if(nil != [[[[self delegate] taskInfo] settings] valueForKey:@"framesToConvert"]) {
			SInt64 startingFrame = [[[[[[self delegate] taskInfo] settings] valueForKey:@"framesToConvert"] valueForKey:@"startingFrame"] longLongValue];
			UInt32 frameCount = [[[[[[self delegate] taskInfo] settings] valueForKey:@"framesToConvert"] valueForKey:@"frameCount"] unsignedIntValue];
			decoder = [RegionDecoder decoderWithFilename:sourceFilename startingFrame:startingFrame frameCount:frameCount];
		}
		else
			decoder = [Decoder decoderWithFilename:sourceFilename];
		
		sampleRate  = (opus_int32) [decoder pcmFormat].mSampleRate;
		numChannels = [decoder pcmFormat].mChannelsPerFrame;

		totalFrames			= [decoder totalFrames];
		framesToRead		= totalFrames;
		
		// Set up the AudioBufferList
		bufferList.mNumberBuffers					= 1;
		bufferList.mBuffers[0].mData				= NULL;
		bufferList.mBuffers[0].mNumberChannels		= numChannels;

		// Allocate the buffer that will hold the interleaved audio data
		bufferLen									= 1024;
		switch([decoder pcmFormat].mBitsPerChannel) {
			
			case 8:				
			case 24:
				bufferList.mBuffers[0].mData			= calloc(bufferLen, sizeof(int8_t));
				bufferList.mBuffers[0].mDataByteSize	= (UInt32)bufferLen * sizeof(int8_t);
				break;
				
			case 16:
				bufferList.mBuffers[0].mData			= calloc(bufferLen, sizeof(int16_t));
				bufferList.mBuffers[0].mDataByteSize	= (UInt32)bufferLen * sizeof(int16_t);
				break;
				
			case 32:
				bufferList.mBuffers[0].mData			= calloc(bufferLen, sizeof(int32_t));
				bufferList.mBuffers[0].mDataByteSize	= (UInt32)bufferLen * sizeof(int32_t);
				break;
				
			default:
				@throw [NSException exceptionWithName:@"IllegalInputException" reason:@"Sample size not supported" userInfo:nil]; 
				break;				
		}
		
		bufferByteSize = bufferList.mBuffers[0].mDataByteSize;
		NSAssert(NULL != bufferList.mBuffers[0].mData, NSLocalizedStringFromTable(@"Unable to allocate memory.", @"Exceptions", @""));
		
		buffer = (opus_int16*) calloc(bufferLen, sizeof(opus_int16));
		NSAssert(NULL != buffer, NSLocalizedStringFromTable(@"Unable to allocate memory.", @"Exceptions", @""));

		// Open the output file
		const char* _out = [filename fileSystemRepresentation];
		comments = ope_comments_create();
		enc = ope_encoder_create_file(_out, comments, (opus_int32) decoder.pcmFormat.mSampleRate, numChannels, 0, NULL);
		NSAssert(NULL != enc, NSLocalizedStringFromTable(@"Unable to create the output file.", @"Exceptions", @""));

		// Check if we should stop, and if so throw an exception
		if([[self delegate] shouldStop])
			@throw [StopException exceptionWithReason:@"Stop requested by user" userInfo:nil];

		// Setup the encoder
		if((_mode < OPUS_MODE_VBR) || (_mode > OPUS_MODE_HARD_CBR))
			@throw [NSException exceptionWithName:@"NSInternalInconsistencyException" reason:@"Unrecognized opus mode" userInfo:nil];

		ope_encoder_ctl(enc, OPUS_SET_VBR((_mode == OPUS_MODE_HARD_CBR) ? 0 : 1));
		ope_encoder_ctl(enc, OPUS_SET_VBR_CONSTRAINT(_mode == OPUS_MODE_VBR) ? 0 : 1);
		ope_encoder_ctl(enc, OPUS_SET_COMPLEXITY(_complexity));
		ope_encoder_ctl(enc, OPUS_SET_BITRATE(_bitrate));

		// Iteratively get the PCM data and encode it
		while(NO == eos) {
			
			// Set up the buffer parameters
			bufferList.mBuffers[0].mNumberChannels	= [decoder pcmFormat].mChannelsPerFrame;
			bufferList.mBuffers[0].mDataByteSize	= bufferByteSize;
			frameCount = bufferList.mBuffers[0].mDataByteSize / [decoder pcmFormat].mBytesPerFrame;

			// Read a chunk of PCM input
			frameCount = [decoder readAudio:&bufferList frameCount:frameCount];

			switch([decoder pcmFormat].mBitsPerChannel) {
				
				case 8:
					buffer8 = bufferList.mBuffers[0].mData;
					for(wideSample = sample = 0; wideSample < frameCount; ++wideSample) {
						for(channel = 0; channel < bufferList.mBuffers[0].mNumberChannels; ++channel, ++sample)
							buffer[sample] = ((opus_int16) buffer8[sample]) << 8;
					}
					break;
					
				case 16:
					buffer16 = bufferList.mBuffers[0].mData;
					for(wideSample = sample = 0; wideSample < frameCount; ++wideSample) {
						for(channel = 0; channel < bufferList.mBuffers[0].mNumberChannels; ++channel, ++sample) {
							buffer[sample] = (opus_int16) OSSwapBigToHostInt16(buffer16[sample]);
						}
					}
					break;
					
				case 24:
					buffer8 = bufferList.mBuffers[0].mData;
					for(wideSample = sample = 0; wideSample < frameCount; ++wideSample) {
						for(channel = 0; channel < bufferList.mBuffers[0].mNumberChannels; ++channel, ++sample) {
							constructedSample = (int8_t)*buffer8++; constructedSample <<= 8;
							constructedSample |= (uint8_t)*buffer8++;

							buffer[sample] = constructedSample;
						}
					}
					break;

				case 32:
					buffer32 = bufferList.mBuffers[0].mData;
					for(wideSample = sample = 0; wideSample < frameCount; ++wideSample) {
						for(channel = 0; channel < bufferList.mBuffers[0].mNumberChannels; ++channel, ++sample)
							buffer[sample] = (opus_int16) (buffer32[sample] / 65536);
					}
					break;
					
				default:
					@throw [NSException exceptionWithName:@"IllegalInputException" reason:@"Sample size not supported" userInfo:nil]; 
					break;
			}
			
			// Write the data
			ope_encoder_write(enc, buffer, frameCount);

			// Update status
			framesToRead -= frameCount;
			
			// Distributed Object calls are expensive, so only perform them every few iterations
			if(0 == iterations % MAX_DO_POLL_FREQUENCY) {
				
				// Check if we should stop, and if so throw an exception
				if([[self delegate] shouldStop])
					@throw [StopException exceptionWithReason:@"Stop requested by user" userInfo:nil];
				
				// Update UI
				percentComplete		= ((double)(totalFrames - framesToRead)/(double) totalFrames) * 100.0;
				interval			= -1.0 * [startTime timeIntervalSinceNow];
				secondsRemaining	= (unsigned) (interval / ((double)(totalFrames - framesToRead)/(double) totalFrames) - interval);
				
				[[self delegate] updateProgress:percentComplete secondsRemaining:secondsRemaining];
			}
			
			++iterations;
			eos = (framesToRead == 0);
		}
	}

	@catch(StopException *exception) {
		[[self delegate] setStopped:YES];
	}
	
	@catch(NSException *exception) {
		[[self delegate] setException:exception];
		[[self delegate] setStopped:YES];
	}
	
	@finally {
		NSException *exception;
		
		// Close the output file
		if(0 != ope_encoder_drain(enc)) {
			exception = [NSException exceptionWithName:@"IOException"
												reason:NSLocalizedStringFromTable(@"Unable to close the output file.", @"Exceptions", @"") 
											  userInfo:[NSDictionary dictionaryWithObjects:[NSArray arrayWithObjects:[NSNumber numberWithInt:errno], [NSString stringWithCString:strerror(errno) encoding:NSASCIIStringEncoding], nil] forKeys:[NSArray arrayWithObjects:@"errorCode", @"errorString", nil]]];
			NSLog(@"%@", exception);
		}

		ope_encoder_destroy(enc);
		ope_comments_destroy(comments);

		// Clean up
		free(bufferList.mBuffers[0].mData);
		free(buffer);
	}

	[[self delegate] setEndTime:[NSDate date]];
	[[self delegate] setCompleted:YES];
}

- (NSString *) settingsString
{
	switch(_mode) {
		case OPUS_MODE_VBR:
			return [NSString stringWithFormat:@"Opus settings: VBR(%ld kbps), COMP(%d)", _bitrate / 1000, _complexity];
			break;
			
		case OPUS_MODE_CVBR:
			return [NSString stringWithFormat:@"Opus settings: CVBR(%ld kbps), COMP(%d)", _bitrate / 1000, _complexity];
			break;
			
		case OPUS_MODE_HARD_CBR:
			return [NSString stringWithFormat:@"Opus settings: CBR(%ld kbps), COMP(%d)", _bitrate / 1000, _complexity];
			break;

		default:
			return nil;
			break;
	}
}

@end

@implementation OggOpusEncoder (Private)

- (void) parseSettings
{
	NSDictionary *settings	= [[self delegate] encoderSettings];
	
	_mode		= [[settings objectForKey:@"mode"] intValue];
	_complexity	= [[settings objectForKey:@"complexity"] intValue];
	_bitrate	= sOpusBitrates[[[settings objectForKey:@"bitrate"] intValue]] * 1000;
}

@end
