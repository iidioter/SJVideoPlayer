//
//  HLSContentIndexReader.m
//  SJMediaCacheServer_Example
//
//  Created by 畅三江 on 2020/6/10.
//  Copyright © 2020 changsanjiang@gmail.com. All rights reserved.
//

#import "HLSContentIndexReader.h"
#import "MCSLogger.h"
#import "MCSAssetFileRead.h" 
#import "HLSAsset.h"
#import "MCSFileManager.h"
#import "MCSQueue.h"

@interface HLSContentIndexReader ()<HLSParserDelegate, MCSAssetDataReaderDelegate>
@property (nonatomic, strong) NSURLRequest *request;

@property (nonatomic) BOOL isCalledPrepare;
@property (nonatomic) BOOL isClosed;

@property (nonatomic, weak, nullable) HLSAsset *asset;
@property (nonatomic, strong, nullable) MCSAssetFileRead *reader;
@property (nonatomic) float networkTaskPriority;
@end

@implementation HLSContentIndexReader
@synthesize delegate = _delegate;
- (instancetype)initWithAsset:(HLSAsset *)asset request:(NSURLRequest *)request networkTaskPriority:(float)networkTaskPriority delegate:(id<MCSAssetDataReaderDelegate>)delegate {
    self = [super init];
    if ( self ) {
        _networkTaskPriority = networkTaskPriority;
        _request = request;
        _asset = asset;
        _delegate = delegate;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@:<%p> { request: %@\n };", NSStringFromClass(self.class), self, _request];
}

- (void)prepare {
    dispatch_barrier_sync(HLSContentIndexReaderQueue(), ^{
        if ( _isClosed || _isCalledPrepare )
            return;
        
        MCSContentReaderDebugLog(@"%@: <%p>.prepare { request: %@\n };", NSStringFromClass(self.class), self, _request);
        
        NSParameterAssert(_asset);
        
        _isCalledPrepare = YES;
        
        HLSParser *_Nullable parser = _asset.parser;
        if ( parser != nil ) {
            [self _prepareReaderForParser:parser];
        }
        else {
            parser = [HLSParser.alloc initWithAsset:_asset.name request:[_request mcs_requestWithHTTPAdditionalHeaders:[_asset.configuration HTTPAdditionalHeadersForDataRequestsOfType:MCSDataTypeHLSPlaylist]] networkTaskPriority:_networkTaskPriority delegate:self];
            [parser prepare];
        }
    });
}

- (nullable MCSAssetFileRead *)reader {
    __block MCSAssetFileRead *reader = nil;
    dispatch_sync(HLSContentIndexReaderQueue(), ^{
        reader = _reader;
    });
    return reader;
}

- (NSData *)readDataOfLength:(NSUInteger)length {
    return [self.reader readDataOfLength:length];
}

- (BOOL)seekToOffset:(NSUInteger)offset {
    return [self.reader seekToOffset:offset];
}

- (void)close {
    dispatch_barrier_sync(HLSContentIndexReaderQueue(), ^{
        [self _close];
    });
}

#pragma mark -

- (NSRange)range {
    return self.reader.range;
}

- (NSUInteger)availableLength {
    return self.reader.availableLength;
}

- (NSUInteger)offset {
    return self.reader.offset;
}

- (BOOL)isPrepared {
    return self.reader.isPrepared;
}

- (BOOL)isDone {
    return self.reader.isDone;
}
  
#pragma mark - HLSParserDelegate

- (void)parserParseDidFinish:(HLSParser *)parser {
    dispatch_barrier_sync(HLSContentIndexReaderQueue(), ^{
        [self _prepareReaderForParser:parser];
    });
}

- (void)parser:(HLSParser *)parser anErrorOccurred:(NSError *)error {
    dispatch_barrier_sync(HLSContentIndexReaderQueue(), ^{
        [self _onError:error];
    });
}

#pragma mark - MCSAssetDataReaderDelegate

- (void)readerPrepareDidFinish:(id<MCSAssetDataReader>)reader {
    [_delegate readerPrepareDidFinish:self];
}

- (void)reader:(id<MCSAssetDataReader>)reader hasAvailableDataWithLength:(NSUInteger)length {
    [_delegate reader:self hasAvailableDataWithLength:length];
}

- (void)reader:(id<MCSAssetDataReader>)reader anErrorOccurred:(NSError *)error {
    dispatch_barrier_sync(HLSContentIndexReaderQueue(), ^{
        [self _onError:error];
    });
}

#pragma mark -

- (void)_onError:(NSError *)error {
    if ( _isClosed )
        return;
    
    MCSContentReaderErrorLog(@"%@: <%p>.error { error: %@ };\n", NSStringFromClass(self.class), self, error);

    [self _close];
    
    dispatch_async(MCSDelegateQueue(), ^{
        [self->_delegate reader:self anErrorOccurred:error];
    });
}

- (void)_close {
    if ( _isClosed )
        return;
    [_reader close];
    _isClosed = YES;
    
    MCSContentReaderDebugLog(@"%@: <%p>.close;\n", NSStringFromClass(self.class), self);
}

- (void)_prepareReaderForParser:(HLSParser *)parser {
    if ( _isClosed ) return;
    if ( _reader != nil ) return;
    
    _parser = parser;
    
    if ( _asset.parser != parser ) {
        _asset.parser = parser;
    }
    
    NSString *indexFilePath = parser.indexFilePath;
    NSUInteger fileSize = [MCSFileManager fileSizeAtPath:indexFilePath];
    NSRange range = NSMakeRange(0, fileSize);
    _reader = [MCSAssetFileRead.alloc initWithAsset:_asset inRange:range path:indexFilePath readRange:range delegate:_delegate];
    [_reader prepare];
}
@end
