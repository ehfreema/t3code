@import Darwin;
@import MachO;
@import UIKit;
@import UniformTypeIdentifiers;
@import Security;

#import "LCUtils.h"
#import "../../LiveContainer/LCSharedUtils.h"
#import "LCAppInfo.h"
#import "../../LiveContainer/LCMachOUtils.h"
#import "../../MultitaskSupport/DecoratedAppSceneViewController.h"
#import "../../ZSign/zsigner.h"
#import "LiveContainerSwiftUI-Swift.h"

// make SFSafariView happy and open data: URLs
@implementation NSURL(hack)
- (BOOL)safari_isHTTPFamilyURL {
    // Screw it, Apple
    return YES;
}
@end

@implementation LCUtils
#pragma mark Certificate & password

+ (NSData *)certificateData {
    // Try the App Group suite first (as shown in Diagnose -> App Group ID), then the known
    // SideStore/AltStore group variants, and finally the app's own defaults. The T3 app can
    // be installed without the store app group being granted (App Group ID: Unknown), so the
    // fallback is what makes the imported certificate usable in that case.
    NSString *appGroup = [LCSharedUtils appGroupID];
    if (appGroup && ![appGroup isEqualToString:@"Unknown"]) {
        NSUserDefaults *groupDefaults = [[NSUserDefaults alloc] initWithSuiteName:appGroup];
        NSData *data = [groupDefaults objectForKey:@"LCCertificateData"];
        if (data) return data;
    }
    // Try the two known store groups with the real team (from the host entitlements or keychain).
    NSString *team = [LCSharedUtils teamIdentifier];
    if (!team.length || [team isEqualToString:@"AAAAAAAAAA"]) {
        team = nil;
    }
    for (NSString *prefix in @[@"group.com.SideStore.SideStore", @"group.com.rileytestut.AltStore"]) {
        NSArray *candidates = team.length
            ? @[[NSString stringWithFormat:@"%@.%@", prefix, team], prefix]
            : @[prefix];
        for (NSString *candidate in candidates) {
            NSUserDefaults *candDefaults = [[NSUserDefaults alloc] initWithSuiteName:candidate];
            NSData *candData = [candDefaults objectForKey:@"LCCertificateData"];
            if (candData) return candData;
        }
    }
    // Final fallback: the app's own defaults (written by the T3 certificate import flow).
    return [NSUserDefaults.standardUserDefaults objectForKey:@"LCCertificateData"];
}


+ (void)setCertificatePassword:(NSString *)certPassword {
    [NSUserDefaults.standardUserDefaults setObject:certPassword forKey:@"LCCertificatePassword"];
    [[[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]] setObject:certPassword forKey:@"LCCertificatePassword"];
}


#pragma mark Multitasking
+ (NSString *)liveProcessBundleIdentifier {
    // first check if we have LiveProcess extension in our own bundle
    NSBundle *liveProcessBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"]];
    if(liveProcessBundle) {
        return liveProcessBundle.bundleIdentifier;
    }
    
    // in LC2, attempt to guess LC1's LiveProcess extension
    NSString *bundleID = [NSString stringWithFormat:@"codes.t3.t3code-live.%@.LiveProcess", LCSharedUtils.teamIdentifier];
    if([NSExtension extensionWithIdentifier:bundleID error:nil]) {
        return bundleID;
    }
    
    return nil;
}

+ (void)launchMultitaskGuestApp:(NSString *)displayName completionHandler:(void (^)(NSNumber *pid, NSError *error))completionHandler {
    if(!self.liveProcessBundleIdentifier) {
        NSError *error = [NSError errorWithDomain:displayName code:2 userInfo:@{NSLocalizedDescriptionKey: @"LiveProcess extension not found. Please reinstall LiveContainer and select Keep Extensions"}];
        if (completionHandler) completionHandler(nil, error);
        return;
    }
    
    NSUserDefaults *lcUserDefaults = NSUserDefaults.standardUserDefaults;
    NSString* bundleId = [lcUserDefaults stringForKey:@"selected"];
    NSString* dataUUID = [lcUserDefaults stringForKey:@"selectedContainer"];
    
    [lcUserDefaults removeObjectForKey:@"selected"];
    [lcUserDefaults removeObjectForKey:@"selectedContainer"];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 16.1, *)) {
            if(UIApplication.sharedApplication.supportsMultipleScenes && [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode"] == 1) {
                [MultitaskWindowManager openAppWindowWithDisplayName:displayName dataUUID:dataUUID bundleId:bundleId pidCallback:completionHandler];
                MultitaskDockManager *dock = [MultitaskDockManager shared];
                [dock addRunningApp:displayName appUUID:dataUUID view:nil];
                return;
            }
        }
        
        UIViewController *rootVC = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.rootViewController;
        DecoratedAppSceneViewController *launcherView = [[DecoratedAppSceneViewController alloc] initWindowName:displayName bundleId:bundleId dataUUID:dataUUID rootVC:rootVC];
        // Wire PID callback
        launcherView.pidAvailableHandler = completionHandler;
        launcherView.view.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        launcherView.view.center = rootVC.view.center;
    });
}

#pragma mark Code signing

+ (NSString *)entitlementsForGuestBundleId:(NSString *)guestBundleId {
    if (!guestBundleId.length) return nil;

    // Determine the REAL team ID: from the imported certificate first (the team that will
    // actually sign the guest), falling back to the host's runtime team. Never use the
    // ad-hoc dummy team "AAAAAAAAAA" from the host IPA.
    NSString *teamId = nil;
    NSData *certData = self.certificateData;
    NSString *certPass = [LCSharedUtils certificatePassword];
    if (certData && certPass) {
        teamId = [self getCertTeamIdWithKeyData:certData password:certPass];
    }
    if (!teamId.length || [teamId isEqualToString:@"AAAAAAAAAA"]) {
        teamId = [LCSharedUtils teamIdentifier];
    }
    if (!teamId.length || [teamId isEqualToString:@"AAAAAAAAAA"]) {
        NSString *hostGroup = [LCSharedUtils appGroupID];
        NSArray *parts = [hostGroup componentsSeparatedByString:@"."];
        NSString *candidate = parts.lastObject;
        if (candidate.length == 10) {
            teamId = candidate;
        }
    }
    if (!teamId.length || [teamId isEqualToString:@"AAAAAAAAAA"]) {
        NSLog(@"[LC] teamId not found for guest entitlements (host team: %@)", [LCSharedUtils teamIdentifier]);
        return nil;
    }

    // Build a minimal, deterministic entitlement set for the guest (JITLess requires the
    // App Group and keychain groups to be shared with the host, matching the attributes
    // shown in the JIT-Less Diagnose screen).
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, guestBundleId];
    dict[@"com.apple.developer.team-identifier"] = teamId;
    dict[@"get-task-allow"] = @YES;
    dict[@"com.apple.developer.kernel.increased-memory-limit"] = @YES;

    // App Groups: the host's active store group (with real team suffix) plus the other store.
    NSString *hostAppGroup = [LCSharedUtils appGroupID];
    NSMutableArray *groups = [NSMutableArray array];
    if (hostAppGroup && ![hostAppGroup isEqualToString:@"Unknown"]) {
        NSString *normalized = hostAppGroup;
        if ([hostAppGroup isEqualToString:@"group.com.SideStore.SideStore"] ||
            [hostAppGroup isEqualToString:@"group.com.rileytestut.AltStore"]) {
            normalized = [NSString stringWithFormat:@"%@.%@", hostAppGroup, teamId];
        }
        if (![groups containsObject:normalized]) [groups addObject:normalized];
    }
    for (NSString *prefix in @[@"group.com.SideStore.SideStore", @"group.com.rileytestut.AltStore"]) {
        NSString *group = [NSString stringWithFormat:@"%@.%@", prefix, teamId];
        if (![groups containsObject:group]) [groups addObject:group];
    }
    dict[@"com.apple.security.application-groups"] = groups;

    // Keychain groups: the 128 T3 shared groups (as shown in Diagnose Entitlement File)
    // plus the guest's own identifier.
    NSMutableArray *keychainGroups = [NSMutableArray array];
    for (int i = 0; i < 128; i++) {
        NSString *group = (i == 0) ? [NSString stringWithFormat:@"%@.codes.t3.t3code-live.shared", teamId]
                                   : [NSString stringWithFormat:@"%@.codes.t3.t3code-live.shared.%d", teamId, i];
        [keychainGroups addObject:group];
    }
    NSString *guestKeychainGroup = [NSString stringWithFormat:@"%@.%@", teamId, guestBundleId];
    if (![keychainGroups containsObject:guestKeychainGroup]) {
        [keychainGroups addObject:guestKeychainGroup];
    }
    dict[@"keychain-access-groups"] = keychainGroups;

    // Serialize to XML
    NSError *error = nil;
    NSData *newData = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
    if (!newData || error) {
        NSLog(@"[LC] failed to serialize guest entitlements: %@", error);
        return nil;
    }
    return [[NSString alloc] initWithData:newData encoding:NSUTF8StringEncoding];
}


+ (void)loadStoreFrameworksWithError2:(NSError **)error {
    // too lazy to use dispatch_once
    static BOOL loaded = NO;
    if (loaded) return;

    void* handle = dlopen("@executable_path/Frameworks/ZSign.dylib", RTLD_GLOBAL);
    const char* dlerr = dlerror();
    if (!handle || (uint64_t)handle > 0xf00000000000) {
        if (dlerr) {
            *error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load ZSign: %s", dlerr]}];
        } else {
            *error = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to load ZSign: An unknown error occurred."]}];
        }
        NSLog(@"[LC] %s", dlerr);
        return;
    }
    
    loaded = YES;
}

+ (NSURL *)storeBundlePath {
    if ([self store] == SideStore) {
        return [LCSharedUtils.storeAppGroupPath URLByAppendingPathComponent:@"Apps/com.SideStore.SideStore/App.app"];
    } else {
        return [LCSharedUtils.storeAppGroupPath URLByAppendingPathComponent:@"Apps/com.rileytestut.AltStore/App.app"];
    }
}

+ (NSString *)storeInstallURLScheme {
    if ([self store] == SideStore) {
        return @"sidestore://install?url=%@";
    } else {
        return @"altstore://install?url=%@";
    }
}

+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *error;

    // use zsign as our signer~
    // Load libraries from Documents, yeah
    [self loadStoreFrameworksWithError2:&error];

    if (error) {
        completionHandler(NO, error);
        return nil;
    }

    NSLog(@"[LC] starting signing... (host team %@, group %@, cert %@)", [LCSharedUtils teamIdentifier], [LCSharedUtils appGroupID], self.certificateData ? @"found" : @"MISSING");

    // Determine the guest's bundle identifier and main executable from its Info.plist
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[path URLByAppendingPathComponent:@"Info.plist"]];
    NSString *guestBundleId = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : nil;
    if (!guestBundleId.length) {
        guestBundleId = NSBundle.mainBundle.bundleIdentifier;
    }
    NSString *guestExecutable = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
    if (!guestExecutable.length) {
        guestExecutable = guestBundleId;
    }
    NSString *mainExecutablePath = [path.path stringByAppendingPathComponent:guestExecutable];

    __block BOOL (^verifySignature)(void) = ^BOOL {
        char messageBuffer[512];
        bool valid = checkCodeSignatureWithError(mainExecutablePath.UTF8String, messageBuffer, sizeof(messageBuffer));
        if (!valid) {
            NSLog(@"[LC] kernel signature check failed: %s", messageBuffer);
        } else {
            NSLog(@"[LC] kernel signature check passed");
        }
        return valid;
    };

    void (^finishWithSuccess)(BOOL, NSString *) = ^(BOOL success, NSString *detail) {
        if (success) {
            completionHandler(YES, nil);
        } else {
            NSError *finalError = [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:@{NSLocalizedDescriptionKey: detail ?: @"lc.signer.latestCertificateInvalidErr"}];
            completionHandler(NO, finalError);
        }
    };

    // Stage 1: sign with entitlements copied from host (real cert team) so the guest
    // inherits the App Groups / keychain groups required for JITLess on iOS 26.
    NSString *entitlements = [self entitlementsForGuestBundleId:guestBundleId];
    if (entitlements) {
        NSLog(@"[LC] stage 1: signing %@ with host entitlements (team %@, group %@)", guestBundleId, [LCSharedUtils teamIdentifier], [LCSharedUtils appGroupID]);
        return [NSClassFromString(@"ZSigner") signWithAppPath:[path path] bundleId:guestBundleId cert:self.certificateData pass:LCSharedUtils.certificatePassword entitlements:entitlements completionHandler:^(BOOL success, NSError *signError) {
            if (success && verifySignature()) {
                finishWithSuccess(YES, nil);
                return;
            }
            char messageBuffer[512];
            checkCodeSignatureWithError(mainExecutablePath.UTF8String, messageBuffer, sizeof(messageBuffer));
            NSLog(@"[LC] stage 1 verification failed (%@); falling back to vanilla signing", signError ? signError.localizedDescription : [NSString stringWithFormat:@"kernel: %s", messageBuffer]);
            // Stage 2: vanilla signing (upstream behavior)
            [NSClassFromString(@"ZSigner") signWithAppPath:[path path] bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData pass:LCSharedUtils.certificatePassword completionHandler:^(BOOL success2, NSError *error2) {
                if (success2 && verifySignature()) {
                    finishWithSuccess(YES, nil);
                    return;
                }
                char messageBuffer2[512];
                bool v = checkCodeSignatureWithError(mainExecutablePath.UTF8String, messageBuffer2, sizeof(messageBuffer2));
                NSString *certTeam = [self getCertTeamIdWithKeyData:self.certificateData password:LCSharedUtils.certificatePassword];
                NSString *detail = [NSString stringWithFormat:@"lc.signer.latestCertificateInvalidErr\nKernel: %s\nCert Team: %@\nHost Team: %@\nHost Group: %@\nStage1: %@\nStage2: %@", v ? "OK" : messageBuffer2, certTeam ?: @"unknown", LCSharedUtils.teamIdentifier ?: @"unknown", LCSharedUtils.appGroupID ?: @"unknown", signError ? signError.localizedDescription : @"signed", error2 ? error2.localizedDescription : @"signed"];
                NSLog(@"[LC] both signing stages failed: %@", detail);
                finishWithSuccess(NO, detail);
            }];
        }];
    }

    // No entitlements available: vanilla signing only
    NSLog(@"[LC] signing %@ with default (empty) entitlements", guestBundleId);
    return [NSClassFromString(@"ZSigner") signWithAppPath:[path path] bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData pass:LCSharedUtils.certificatePassword completionHandler:^(BOOL success, NSError *signError) {
        if (success && verifySignature()) {
            finishWithSuccess(YES, nil);
            return;
        }
        char messageBuffer[512];
        bool v = checkCodeSignatureWithError(mainExecutablePath.UTF8String, messageBuffer, sizeof(messageBuffer));
        NSString *certTeam = [self getCertTeamIdWithKeyData:self.certificateData password:LCSharedUtils.certificatePassword];
        NSString *detail = [NSString stringWithFormat:@"lc.signer.latestCertificateInvalidErr\nKernel: %s\nCert Team: %@\nHost Team: %@\nHost Group: %@", v ? "OK" : messageBuffer, certTeam ?: @"unknown", LCSharedUtils.teamIdentifier ?: @"unknown", LCSharedUtils.appGroupID ?: @"unknown"];
        NSLog(@"[LC] signing failed: %@", detail);
        finishWithSuccess(NO, detail);
    }];
}

+ (NSProgress *)signFilesWithZSignWithURLs:(NSArray<NSURL*>*)urls completionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    NSError *error;
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        completionHandler(NO, error);
        return nil;
    }
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[urls count]];
    for (NSURL *url in urls) {
        [paths addObject:url.path];
    }
    
    return [NSClassFromString(@"ZSigner") signMachOPathArr:paths bundleId:NSBundle.mainBundle.bundleIdentifier cert:self.certificateData
                                                      pass:LCSharedUtils.certificatePassword completionHandler:completionHandler];
}

+ (NSString*)getCertTeamIdWithKeyData:(NSData*)keyData password:(NSString*)password {
    NSError *error;
    [self loadStoreFrameworksWithError2:&error];
    if (error) {
        return nil;
    }
    NSString* ans = [NSClassFromString(@"ZSigner") getTeamIdWithCert:keyData pass:password];
    return ans;
}

+ (int)validateCertificateWithCompletionHandler:(void(^)(int status, NSDate *expirationDate, NSString *organizationalUnitName, NSString *error))completionHandler {
    NSError *error;
    NSData *certData = [LCUtils certificateData];
    if (error) {
        return -6;
    }
    [self loadStoreFrameworksWithError2:&error];
    int ans = [NSClassFromString(@"ZSigner") checkCert:certData pass:[LCSharedUtils certificatePassword] completionHandler:completionHandler];
    return ans;
}

#pragma mark Setup

+ (Store) store {
    static Store ans;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // use uttype to accurately detect store
        if([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.sidestore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = SideStore;
        } else if ([UTType typeWithIdentifier:[NSString stringWithFormat:@"io.altstore.Installed.%@", NSBundle.mainBundle.bundleIdentifier]]) {
            ans = AltStore;
        } else {
            ans = Unknown;
        }
        
        if(ans != Unknown) {
            return;
        }
        
        if([[LCSharedUtils appGroupID] containsString:@"AltStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.rileytestut.AltStore"]) {
            ans = AltStore;
        } else if ([[LCSharedUtils appGroupID] containsString:@"SideStore"] && ![[LCSharedUtils appGroupID] isEqualToString:@"group.com.SideStore.SideStore"]) {
            ans = SideStore;
        } else if (![[LCSharedUtils appGroupID] containsString:@"Unknown"] ) {
            ans = ADP;
        } else {
            ans = Unknown;
        }
    });
    return ans;
}

+ (NSString *)appUrlScheme {
    return NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0];
}

+ (BOOL)isAppGroupAltStoreLike {
    return [LCSharedUtils.appGroupID containsString:@"SideStore"] || [LCSharedUtils.appGroupID containsString:@"AltStore"];
}

+ (void)changeMainExecutableTo:(NSString *)exec error:(NSError **)error {
    NSURL *infoPath = [LCSharedUtils.appGroupPath URLByAppendingPathComponent:@"LiveContainer/Applications/codes.t3.t3code-live.app/Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfURL:infoPath];
    if (!infoDict) return;

    infoDict[@"CFBundleExecutable"] = exec;
    [infoDict writeToURL:infoPath error:error];
}

+ (void)validateJITLessSetupWithCompletionHandler:(void (^)(BOOL success, NSError *error))completionHandler {
    // Verify that the certificate is usable
    // Create a test app bundle
    NSString *path = NSTemporaryDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpLibPath = [path stringByAppendingPathComponent:@"TestJITLess.dylib"];
    [NSFileManager.defaultManager copyItemAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/TestJITLess.dylib"] toPath:tmpLibPath error:nil];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block bool signSuccess = false;
    __block NSError* signError = nil;
    
    // Sign the test app bundle

    [LCUtils signFilesWithZSignWithURLs:@[[NSURL fileURLWithPath:tmpLibPath]]
                  completionHandler:^(BOOL success, NSError *_Nullable error) {
        signSuccess = success;
        signError = error;
        dispatch_semaphore_signal(sema);
    }];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if(!signSuccess) {
            completionHandler(NO, signError);
        } else {
            char messageBuffer[512];
            bool valid = checkCodeSignatureWithError([tmpLibPath UTF8String], messageBuffer, sizeof(messageBuffer));
            if (valid) {
                completionHandler(YES, signError);
            } else {
                NSString *certTeam = [LCUtils getCertTeamIdWithKeyData:[LCUtils certificateData] password:LCSharedUtils.certificatePassword];
                NSString *detailed = [NSString stringWithFormat:@"lc.signer.latestCertificateInvalidErr\nKernel: %s\nCert Team: %@\nHost Team: %@\nHost Group: %@", messageBuffer, certTeam ?: @"unknown", LCSharedUtils.teamIdentifier ?: @"unknown", LCSharedUtils.appGroupID ?: @"unknown"];
                completionHandler(NO, [NSError errorWithDomain:NSBundle.mainBundle.bundleIdentifier code:2 userInfo:@{NSLocalizedDescriptionKey: detailed}]);
            }
        }
        [NSFileManager.defaultManager removeItemAtPath:tmpLibPath error:nil];
    });
}

+ (NSURL *)archiveIPAWithBundleName:(NSString*)newBundleName includingExtraInfoDict:(NSDictionary *)extraInfoDict error:(NSError **)error {
    if (*error) return nil;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *bundlePath = NSBundle.mainBundle.bundleURL;

    NSURL *tmpPath = manager.temporaryDirectory;

    NSURL *tmpPayloadPath = [tmpPath URLByAppendingPathComponent:@"LiveContainer2/Payload"];
    [manager removeItemAtURL:tmpPayloadPath error:nil];
    [manager createDirectoryAtURL:tmpPayloadPath withIntermediateDirectories:YES attributes:nil error:error];
    if (*error) return nil;
    
    NSURL *tmpIPAPath = [tmpPath URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipa", newBundleName]];
    

    [manager copyItemAtURL:bundlePath toURL:[tmpPayloadPath URLByAppendingPathComponent:@"App.app"] error:error];
    if (*error) return nil;
    
    NSURL *infoPath = [tmpPayloadPath URLByAppendingPathComponent:@"App.app/Info.plist"];
    NSMutableDictionary *infoDict = [NSMutableDictionary dictionaryWithContentsOfURL:infoPath];
    if (!infoDict) return nil;

    infoDict[@"CFBundleDisplayName"] = newBundleName;
    infoDict[@"CFBundleName"] = newBundleName;
    infoDict[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"com.kdt.%@", newBundleName];
    infoDict[@"CFBundleURLTypes"][0][@"CFBundleURLSchemes"][0] = [newBundleName lowercaseString];
    while([infoDict[@"CFBundleURLTypes"] count] > 1) {
        [infoDict[@"CFBundleURLTypes"] removeLastObject];
    }
    [infoDict removeObjectForKey:@"UTExportedTypeDeclarations"];
    infoDict[@"CFBundleIconName"] = @"AppIconGrey";
    if (infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"]) {
        infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"] = @"AppIconGrey";
    }
    infoDict[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][0] = @"AppIconGrey60x60";
    
    if (infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"]) {
        infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"] = @"AppIconGrey";
    }
    infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][0] = @"AppIconGrey60x60";
    infoDict[@"CFBundleIcons~ipad"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"][1] = @"AppIconGrey76x76";
    [infoDict addEntriesFromDictionary:extraInfoDict];
    
    // reset a executable name so they don't look the same on the log
    NSURL* appBundlePath = [tmpPayloadPath URLByAppendingPathComponent:@"App.app"];
    
    NSURL* execFromPath = [appBundlePath URLByAppendingPathComponent:infoDict[@"CFBundleExecutable"]];
    infoDict[@"CFBundleExecutable"] = newBundleName;
    NSURL* execToPath = [appBundlePath URLByAppendingPathComponent:infoDict[@"CFBundleExecutable"]];
    
    // MARK: patch main executable
    // we remove the teamId after app group id so it can be correctly signed by AltSign.
    NSString* entitlementXML = getLCEntitlementXML();
    NSData *plistData = [entitlementXML dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSPropertyListSerialization propertyListWithData:plistData
                                                                          options:NSPropertyListMutableContainers
                                                                           format:nil
                                                                            error:error];
    if(*error) {
        return nil;
    }
    
    NSString* teamId = dict[@"com.apple.developer.team-identifier"];
    if(![teamId isKindOfClass:NSString.class]) {
        *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"com.apple.developer.team-identifier is not a string!"}];
        return nil;
    }
    infoDict[@"PrimaryLiveContainerTeamId"] = teamId;
    NSArray* appGroupsToFind = @[
        @"group.com.SideStore.SideStore",
        @"group.com.rileytestut.AltStore",
    ];
    
    // remove the team id prefix in app group id added by SideStore/AltStore
    for(NSString* appGroup in appGroupsToFind) {
        NSUInteger appGroupCount = [dict[@"com.apple.security.application-groups"] count];
        for(int i = 0; i < appGroupCount; ++i) {
            NSString* targetAppGroup = [NSString stringWithFormat:@"%@.%@", appGroup, teamId];
            if([dict[@"com.apple.security.application-groups"][i] isEqualToString:targetAppGroup]) {
                dict[@"com.apple.security.application-groups"][i] = appGroup;
            }
        }
    }
    
    // set correct application-identifier
    dict[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, infoDict[@"CFBundleIdentifier"]];
    
    // For TrollStore
    NSString* containerId = dict[@"com.apple.private.security.container-required"];
    if(containerId) {
        dict[@"com.apple.private.security.container-required"] = infoDict[@"CFBundleIdentifier"];
    }
    
    
    // We have to change executable's UUID so iOS won't consider 2 executables the same
    NSString* errorChangeUUID = LCParseMachO([execFromPath.path UTF8String], false, ^(const char *path, struct mach_header_64 *header, int fd, void* filePtr) {
        LCChangeMachOUUID(header);
    });
    if (errorChangeUUID) {
        NSMutableDictionary* details = [NSMutableDictionary dictionary];
        [details setValue:errorChangeUUID forKey:NSLocalizedDescriptionKey];
        // populate the error object with the details
        *error = [NSError errorWithDomain:@"world" code:200 userInfo:details];
        NSLog(@"[LC] %@", errorChangeUUID);
        return nil;
    }
    
    NSData* newEntitlementData = [NSPropertyListSerialization dataWithPropertyList:dict format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    [LCUtils loadStoreFrameworksWithError2:error];
    BOOL adhocSignSuccess = [NSClassFromString(@"ZSigner") adhocSignMachOAtPath:execFromPath.path bundleId:infoDict[@"CFBundleIdentifier"] entitlementData:newEntitlementData];
    if (!adhocSignSuccess) {
        *error = [NSError errorWithDomain:@"archiveIPAWithBundleName" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"Failed to adhoc sign main executable!"}];
        return nil;
    }
    
    // MARK: archive bundle
    
    [manager moveItemAtURL:execFromPath toURL:execToPath error:error];
    if (*error) {
        NSLog(@"[LC] %@", *error);
        return nil;
    }
    
    // we don't care about errors when removing unnecessary files. errors occur probably because the file does not exist
    // we remove the extension
    [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"PlugIns"] error:nil];
    // remove all sidestore stuff
    if([NSUserDefaults sideStoreExist]) {
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStoreSupport.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStore.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Frameworks/SideStoreApp.framework"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Intents.intentdefinition"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"ViewApp.intentdefinition"] error:nil];
        [manager removeItemAtURL:[appBundlePath URLByAppendingPathComponent:@"Metadata.appintents"] error:nil];
        [infoDict removeObjectForKey:@"INIntentsSupported"];
        [infoDict removeObjectForKey:@"NSUserActivityTypes"];
    }
    
    [infoDict writeToURL:infoPath error:error];
    
    dlopen("/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore", RTLD_GLOBAL);
    NSData *zipData = [[NSClassFromString(@"PKZipArchiver") new] zippedDataForURL:tmpPayloadPath.URLByDeletingLastPathComponent];
    if (!zipData) return nil;

    [manager removeItemAtURL:tmpPayloadPath error:error];
    if (*error) return nil;
    
    if([manager fileExistsAtPath:tmpIPAPath.path]) {
        [manager removeItemAtURL:tmpIPAPath error:error];
        if (*error) return nil;
    }

    [zipData writeToURL:tmpIPAPath options:0 error:error];
    if (*error) return nil;

    return tmpIPAPath;
}

+ (NSString *)getVersionInfo {
    return [NSString stringWithFormat:@"Version %@-%@",
            NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
            NSBundle.mainBundle.infoDictionary[@"LCVersionInfo"]];
}

+ (NSData*)bookmarkForURL:(NSURL*) url {
    return [url bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
}


@end
