//
//  main.swift
//  Player
//
//  Created by Bao Pham on 10/13/15.
//  Copyright © 2015 BaoPham. All rights reserved.
//

import Foundation
import AudioToolbox

let kNumberPlaybackBuffers = 3 //one being played, one filled, and one in the queue to account for lag
// Change to your path
let kPlaybackFileLocation = "/Users/baopham/Desktop/DemoSong.wav" as CFString

class Player{
    var playbackFile: AudioFileID = nil
    var packetPosition: Int64 = 0 //can store 2^64 values
    var numPacketsToRead: UInt32 = 0
    var packetDescs: UnsafeMutablePointer<AudioStreamPacketDescription> = nil //wrap around C data type to make it Swifty...
    var isDone = false
}

//utility functions
func CheckError(error: OSStatus, operation: String) {
    guard error != noErr else {
        return
    }
    
    var result: String = ""
    var char = Int(error.bigEndian)
    
    for _ in 0..<4 {
        guard isprint(Int32(char&255)) == 1 else {
            result = "\(error)"
            break
        }
        result.append(UnicodeScalar(char&255))
        char = char/256
    }
    
    print("Error: \(operation) (\(result))")
    
    exit(1)
}

func CopyEncoderCookieToQueue(theFile: AudioFileID, queue: AudioQueueRef) {
    var propertySize = UInt32()
    let result = AudioFileGetPropertyInfo(theFile, kAudioFilePropertyMagicCookieData, &propertySize, nil)
    
    if result == noErr && propertySize > 0 {
        let magicCookie = UnsafeMutablePointer<UInt8>(malloc(sizeof(UInt8) * Int(propertySize)))
        
        CheckError(AudioFileGetProperty(theFile, kAudioFilePropertyMagicCookieData, &propertySize, magicCookie), operation: "Get cookie from file failed")
        
        CheckError(AudioQueueSetProperty(queue, kAudioQueueProperty_MagicCookie, magicCookie, propertySize), operation: "Set cookie on queue failed")
        
        free(magicCookie)
    }
}

func CalculateBytesForTime(inAudioFile: AudioFileID, inDesc: AudioStreamBasicDescription, inSeconds: Double, inout outBufferSize: UInt32, inout outNumPackets: UInt32) {
    var maxPacketSize = UInt32()
    var propSize = UInt32(sizeof(maxPacketSize.dynamicType))
    
    CheckError(AudioFileGetProperty(inAudioFile, kAudioFilePropertyPacketSizeUpperBound, &propSize, &maxPacketSize), operation: "Couldn't get file's max packet size")
    
    let maxBufferSize: UInt32 = 0x10000
    let minBufferSize: UInt32 = 0x4000
    
    if inDesc.mFramesPerPacket > 0 {
        let numPacketsForTime = inDesc.mSampleRate / Double(inDesc.mFramesPerPacket) * inSeconds
        
        outBufferSize = UInt32(numPacketsForTime) * maxPacketSize
    } else {
        outBufferSize = maxBufferSize > maxPacketSize ? maxBufferSize : maxPacketSize
    }
    
    if outBufferSize > maxBufferSize && outBufferSize > maxPacketSize {
        outBufferSize = maxBufferSize
    } else {
        if outBufferSize < minBufferSize {
            outBufferSize = minBufferSize
        }
    }
    
    outNumPackets = outBufferSize / maxPacketSize
}

//Playback callback function
let AQOutputCallback: AudioQueueOutputCallback = {(inUserData, inAQ, inCompleteAQBuffer) -> () in
    let aqp = UnsafeMutablePointer<Player>(inUserData).memory
    
    guard !aqp.isDone else {
        return
    }
    
    var numBytes = UInt32()
    var nPackets = aqp.numPacketsToRead
    
    // AudioFileReadPackets was deprecated in OS X 10.10 and iOS 8
    CheckError(AudioFileReadPacketData(aqp.playbackFile, false, &numBytes, aqp.packetDescs, aqp.packetPosition, &nPackets, inCompleteAQBuffer.memory.mAudioData), operation: "AudioFileReadPacketData failed")
    
    if nPackets > 0 {
        inCompleteAQBuffer.memory.mAudioDataByteSize = numBytes
        AudioQueueEnqueueBuffer(inAQ, inCompleteAQBuffer, (aqp.packetDescs != nil ? nPackets : 0), aqp.packetDescs)
        
        aqp.packetPosition+=Int64(nPackets)
    } else {
        CheckError(AudioQueueStop(inAQ, false), operation: "AudioQueueStop failed")
        aqp.isDone = true
    }
}

func main(){
    var error = noErr
    
    //SET UP THE AUDIO QUEUE
    
    //open an audio file
    var player = Player()
    let fileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, kPlaybackFileLocation, CFURLPathStyle.CFURLPOSIXPathStyle, false)
    
    error = AudioFileOpenURL(fileURL, AudioFilePermissions.ReadPermission, 0, &player.playbackFile) //this explains the & http://stackoverflow.com/questions/30541244/what-does-a-ampersand-mean-in-the-swift-language
    
    CheckError(error, operation: "AudioFileOpenURL failed")
    
    //set up format
    var dataFormat = AudioStreamBasicDescription() //describing the audio format being provided to the queue
    var propSize = UInt32(sizeof(dataFormat.dynamicType)) //dynamicType will print out the type of the variable
    
    error = AudioFileGetProperty(player.playbackFile, kAudioFilePropertyDataFormat, &propSize, &dataFormat) //get the needed size
    
    CheckError(error, operation: "Couldn't get file's data format")
    
    
    //set up queue
    var queue = AudioQueueRef()
    
    error = AudioQueueNewOutput(&dataFormat, AQOutputCallback, &player, nil, nil, 0, &queue)
    
    CheckError(error, operation: "AudioQueueNewOutput failed")
    
    //SET UP THE BUFFER
    
    //calculate playback buffer size and number of packets to read
    //frame is a single sample of audio data
    //buffer size is the amount of memory that a part of audio is stored before it gets to the CPU.
    //packet is a collection of frames
    var bufferByteSize = UInt32()
    CalculateBytesForTime(player.playbackFile, inDesc: dataFormat, inSeconds: 0.5, outBufferSize: &bufferByteSize, outNumPackets: &player.numPacketsToRead)
    
    //allocate memory for packet description array
    let isFormatVBR = (dataFormat.mBytesPerPacket == 0 || dataFormat.mFramesPerPacket == 0) //size and frame per packets
    
    if isFormatVBR{
        player.packetDescs = UnsafeMutablePointer<AudioStreamPacketDescription>(malloc(sizeof(AudioStreamBasicDescription) * Int(player.numPacketsToRead)))
    }else{
        player.packetDescs = nil
    }
    
    CopyEncoderCookieToQueue(player.playbackFile, queue: queue)
    
    //allocating and enqueuing playback buffers
    var buffers = [AudioQueueBufferRef](count: kNumberPlaybackBuffers, repeatedValue: AudioQueueBufferRef())
    
    player.isDone = false
    player.packetPosition = 0
    
    for i in 0..<kNumberPlaybackBuffers{
        error = AudioQueueAllocateBuffer(queue, bufferByteSize, &buffers[i])
        CheckError(error, operation: "AudioQueueAllocateBuffer failed")
        
        AQOutputCallback(&player, queue, buffers[i])
        
        if player.isDone{
            break
        }
    }
    
    //START THE PLAYBACK QUEUE
    error = AudioQueueStart(queue, nil)
    CheckError(error, operation: "AudioQueueStart failed")
    
    print("Playing...\n")
    repeat{
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false)
    } while (!player.isDone)
    
    //delaying to ensure queue plays out buffered audio
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 2, false)
    
    //cleaning up the audio queue and audio file
    player.isDone = true
    error = AudioQueueStop(queue, true)
    CheckError(error, operation: "AudioQueueStop failed")
    AudioQueueDispose(queue, true)
    AudioFileClose(player.playbackFile)
}

main()
