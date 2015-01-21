//
//  SonosDiscovery.h
//  SonosKit
//
//  Created by Nathan Borror on 3/16/14.
//  Copyright (c) 2014 Nathan Borror. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SonosDiscovery : NSObject

+ (void)discoverControllers:(void(^)(NSArray *controllers, NSString *householdId , NSError *error))completion;

@end
