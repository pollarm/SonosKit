//
//  SonosDiscovery.h
//  SonosKit
//
//  Created by Nathan Borror on 3/16/14.
//  Copyright (c) 2014 Nathan Borror. All rights reserved.
//

#import "SonosDiscovery.h"
#import "XMLReader.h"
#import "SonosController.h"
#import <GCDAsyncUdpSocket.h>

typedef void (^kFindControllersBlock)(NSArray *ipAddresses, NSString *household);

@interface SonosDiscovery () <GCDAsyncUdpSocketDelegate>
@end

@implementation SonosDiscovery {
  GCDAsyncUdpSocket *_udpSocket;
  kFindControllersBlock _completionBlock;
  NSArray *_ipAddresses;
    NSString *_household;
}

+ (void)discoverControllers:(void(^)(NSArray *controllers, NSString *householdId, NSError *error))completion
{
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    SonosDiscovery *discover = [[SonosDiscovery alloc] init];

    [discover findControllers:^(NSArray *ipAddresses, NSString *household) {
      NSMutableArray *controllers = [[NSMutableArray alloc] init];

      if (ipAddresses.count == 0) {

        completion(nil, nil, nil);
        return;

      }

      NSString *ipAddress = [ipAddresses objectAtIndex:0];
      NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/status/topology", ipAddress]];
      NSURLRequest *request = [[NSURLRequest alloc] initWithURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];

      NSURLSession *session = [NSURLSession sharedSession];
      NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) return;

          NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
          NSDictionary *responseDict = [XMLReader dictionaryForXMLString:raw error:&error];
        NSArray *inputs = responseDict[@"ZPSupportInfo"][@"ZonePlayers"][@"ZonePlayer"];
          // crashed here at Andys ... possible because only a single zone?
        for (NSDictionary *input in inputs) {
          NSString *ipLocation = input[@"location"];
          NSRegularExpression *ipRegex = [NSRegularExpression regularExpressionWithPattern:@"\\d{1,3}.\\d{1,3}.\\d{1,3}.\\d{1,3}" options:0 error:nil];
          NSTextCheckingResult *ipRegexMatch = [ipRegex firstMatchInString:ipLocation options:0 range:NSMakeRange(0, ipLocation.length)];
          NSString *ip = [ipLocation substringWithRange:ipRegexMatch.range];
          BOOL coordinator = [input[@"coordinator"] isEqualToString:@"true"] ? YES : NO;

          if ([input[@"text"] rangeOfString:@"Bridge"].location == NSNotFound) {
            [controllers addObject:@{
                                     @"ip": ip,
                                     @"name": input[@"text"],
                                     @"coordinator": [NSNumber numberWithBool:coordinator],
                                     @"uuid": input[@"uuid"],
                                     @"group": input[@"group"]
                                     }];
          }
        }
          
          if(controllers.count == 0) {
              NSLog(@"%@", raw);
          }

        dispatch_async(dispatch_get_main_queue(), ^{
          completion(controllers, household, error);
        });
      }];

      [task resume];
    }];
  });
}

- (void)findControllers:(kFindControllersBlock)block
{
    NSLog(@"SonosDiscovery findControllers");
    
  _completionBlock = block;
  _ipAddresses = [NSArray array];
  _udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];

  NSError *error = nil;
  if (![_udpSocket bindToPort:0 error:&error]) {
    NSLog(@"Error binding");
  }

  if (![_udpSocket beginReceiving:&error]) {
    NSLog(@"Error receiving");
  }

  [_udpSocket enableBroadcast:YES error:&error];
  if (error) {
    NSLog(@"Error enabling broadcast");
  }

  NSString *data = @"M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp: discover\"\r\nMX: 3\r\nST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n";
  [_udpSocket sendData:[data dataUsingEncoding:NSUTF8StringEncoding] toHost:@"239.255.255.250" port:1900 withTimeout:-1 tag:0];

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [self stopDiscovery];
  });
}

- (void)stopDiscovery
{
    if (_udpSocket) {
        _completionBlock(_ipAddresses, _household);
    }
  [_udpSocket close];
  _udpSocket = nil;
    NSLog(@"stopDiscovery %lu _ipAddresses", (unsigned long)_ipAddresses.count);
  
}


#pragma mark - GCDAsyncUdpSocketDelegate

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext
{
    NSString *msg = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (msg && [msg rangeOfString:@"urn:schemas-upnp-org:device:ZonePlayer"].location != NSNotFound) {
        NSLog(@"%@", msg);
        NSRegularExpression *reg = [[NSRegularExpression alloc] initWithPattern:@"http:\\/\\/(.*?)\\/" options:0 error:nil];
        NSArray *matches = [reg matchesInString:msg options:0 range:NSMakeRange(0, msg.length)];
        
        NSString *household = nil;
        NSRange householdHeaderRange = [msg rangeOfString:@"X-RINCON-HOUSEHOLD: "];
        if(householdHeaderRange.location != NSNotFound) {
            NSString *householdAndRest = [msg substringFromIndex:householdHeaderRange.location+householdHeaderRange.length];
            NSRange householdEndRange = [householdAndRest rangeOfString:@"\r"];
            if(householdEndRange.location != NSNotFound) {
                household = [householdAndRest substringToIndex:householdEndRange.location];
            }
        }
        
        if (matches.count > 0 && household) { // eg. HHID_vQi8ojPG58Ctex7ZxjaUdtiXcKg
            NSTextCheckingResult *result = matches[0];
            NSString *matched = [msg substringWithRange:[result rangeAtIndex:0]];
            NSString *ip = [[matched substringFromIndex:7] substringToIndex:matched.length-8];
            _ipAddresses = [_ipAddresses arrayByAddingObject:ip];
            _household = household;
            [self stopDiscovery];
        }
    }
}

@end
