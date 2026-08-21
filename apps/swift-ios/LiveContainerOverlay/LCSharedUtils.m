#import "LCSharedUtils.h"
#import "FoundationPrivate.h"
#import "UIKitPrivate.h"
#import "utils.h"
@import MachO;

extern NSUserDefaults *lcUserDefaults;
extern NSString *lcAppUrlScheme;
extern NSBundle *lcMainBundle;

NSString* FBSOpenApplicationOptionKeyActivateAsClassic = @"__ActivateAsClassic";
NSString* FBSOpenApplicationOptionKeyPayloadURL = @"__PayloadURL";

@implementation LCSharedUtils

+ (NSString*) teamIdentifier {
    static NSString* ans = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if !TARGET_OS_SIMULATOR
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFErrorRef error = NULL;
        CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.team-identifier"), &error);
        if(cfans && CFGetTypeID(cfans) == CFStringGetTypeID()) {
            ans = (__bridge NSString*)cfans;
        }
        CFRelease(taskSelf);
#endif
        if(!ans) {
            // the above seems not to work if the device is jailbroken by Palera1n, so we use the public api one as backup
            // https://stackoverflow.com/a/11841898
            NSString *tempAccountName = @"bundleSeedID";
            NSDictionary *query = @{
                (__bridge NSString *)kSecClass : (__bridge NSString *)kSecClassGenericPassword,
                (__bridge NSString *)kSecAttrAccount : tempAccountName,
                (__bridge NSString *)kSecAttrService : @"",
                (__bridge NSString *)kSecReturnAttributes: (__bridge NSNumber *)kCFBooleanTrue,
            };
            CFDictionaryRef result = nil;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecItemNotFound)
                status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecSuccess) {
                status = SecItemDelete((__bridge CFDictionaryRef)query); // remove temp item
                NSDictionary *dict = (__bridge_transfer NSDictionary *)result;
                NSString *accessGroup = dict[(__bridge NSString *)kSecAttrAccessGroup];
                NSArray *components = [accessGroup componentsSeparatedByString:@"."];
                NSString *bundleSeedID = [[components objectEnumerator] nextObject];
                ans = bundleSeedID;
            }
        }
    });
    // If we got the ad-hoc dummy team, try to get the real team from the certificate's App Group
    // (as shown in Diagnose → Certificate Team ID). This handles the case where the host IPA was
    // ad-hoc signed with AAAAAAAAAA but the real cert is in SideStore's group.
    if ([ans isEqualToString:@"AAAAAAAAAA"] || ans.length != 10) {
        // Try to find the real team from any App Group that contains LCCertificateData
        for (NSString *prefix in @[@"group.com.SideStore.SideStore", @"group.com.rileytestut.AltStore"]) {
            // Try with any team suffix found in entitlements
            CFErrorRef error = NULL;
            void* taskSelf = SecTaskCreateFromSelf(NULL);
            CFTypeRef entValue = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.security.application-groups"), &error);
            CFRelease(taskSelf);
            NSArray *entGroups = (entValue && CFGetTypeID(entValue) == CFArrayGetTypeID())
                ? (__bridge NSArray *)entValue
                : @[];
            for (NSString *g in entGroups) {
                if ([g isKindOfClass:NSString.class] && [g hasPrefix:prefix] && g.length > prefix.length + 1) {
                    NSString *team = [[g componentsSeparatedByString:@"."] lastObject];
                    if (team.length == 10 && ![team isEqualToString:@"AAAAAAAAAA"]) {
                        // Verify this group actually has a cert
                        NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:g];
                        if ([ud objectForKey:@"LCCertificateData"]) {
                            ans = team;
                            return ans;
                        }
                    }
                }
            }
            // Also try the SideStore/AltStore groups with any team that has Apps folder
            // Brute force check for common team pattern by looking at file system for group containers
            // We can't enumerate teams, but we can check if the current App Group (with dummy) has cert, if not try the other
        }
        // Fallback: try to read team from the certificate data itself if we can find it
        // Try all candidate groups for LCCertificateData and extract team via keychain
        NSArray *fallbackGroups = @[@"group.com.SideStore.SideStore", @"group.com.rileytestut.AltStore"];
        for (NSString *prefix in fallbackGroups) {
            for (NSString *candidate in @[prefix, [prefix stringByAppendingString:@".AAAAAAAAAA"]]) {
                NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:candidate];
                NSData *certData = [ud objectForKey:@"LCCertificateData"];
                NSString *certPass = [ud objectForKey:@"LCCertificatePassword"];
                if (certData && certPass) {
                    // We have cert, try to get team from keychain via cert (handled in LCUtils, but we can try here)
                    // For now, just return the team from the group suffix if it looks like a team
                    NSArray *parts = [candidate componentsSeparatedByString:@"."];
                    NSString *maybeTeam = parts.lastObject;
                    if (maybeTeam.length == 10 && ![maybeTeam isEqualToString:@"AAAAAAAAAA"] && ![maybeTeam isEqualToString:@"AltStore"] && ![maybeTeam isEqualToString:@"SideStore"]) {
                        ans = maybeTeam;
                        return ans;
                    }
                }
            }
        }
    }
    return ans;
}

+ (NSString *)appGroupID {
    static dispatch_once_t once;
    static NSString *appGroupID = @"Unknown";
    dispatch_once(&once, ^{
        // Build candidate list with both current team and any team found in entitlements/certificate.
        // This handles the ad-hoc case where teamIdentifier is AAAAAAAAAA but real team is in SideStore group.
        NSMutableArray *candidates = [NSMutableArray array];
        NSString *currentTeam = [self teamIdentifier];
        if (currentTeam.length) {
            [candidates addObject:[@"group.com.SideStore.SideStore." stringByAppendingString:currentTeam]];
            [candidates addObject:[@"group.com.rileytestut.AltStore." stringByAppendingString:currentTeam]];
        }
        // Also try without team suffix (ad-hoc) and try to discover real team from any accessible group that has certificate
        [candidates addObject:@"group.com.SideStore.SideStore"];
        [candidates addObject:@"group.com.rileytestut.AltStore"];
        // Try to extract team from entitlements groups (real team after SideStore re-sign)
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFTypeRef entGroupsValue = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.security.application-groups"), &error);
        CFRelease(taskSelf);
        NSArray *entGroups = (entGroupsValue && CFGetTypeID(entGroupsValue) == CFArrayGetTypeID())
            ? (__bridge NSArray *)entGroupsValue
            : @[];
        for (NSString *g in entGroups) {
            if (![g isKindOfClass:NSString.class]) continue;
            if ([g hasPrefix:@"group.com.SideStore.SideStore."] || [g hasPrefix:@"group.com.rileytestut.AltStore."]) {
                if (![candidates containsObject:g]) [candidates addObject:g];
                // Extract team suffix and add the two prefixes with that team
                NSArray *parts = [g componentsSeparatedByString:@"."];
                NSString *team = parts.lastObject;
                if (team.length == 10) {
                    NSString *side = [NSString stringWithFormat:@"group.com.SideStore.SideStore.%@", team];
                    NSString *alt = [NSString stringWithFormat:@"group.com.rileytestut.AltStore.%@", team];
                    if (![candidates containsObject:side]) [candidates addObject:side];
                    if (![candidates containsObject:alt]) [candidates addObject:alt];
                }
            } else if ([g isEqualToString:@"group.com.SideStore.SideStore"] || [g isEqualToString:@"group.com.rileytestut.AltStore"]) {
                if (![candidates containsObject:g]) [candidates addObject:g];
            }
        }
        // Also try any group that actually contains LCCertificateData (real SideStore group)
        for (NSString *prefix in @[@"group.com.SideStore.SideStore", @"group.com.rileytestut.AltStore"]) {
            // Check if any candidate with that prefix has certificate
            for (NSString *cand in [candidates copy]) {
                if ([cand hasPrefix:prefix]) {
                    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:cand];
                    if ([ud objectForKey:@"LCCertificateData"]) {
                        // This group has cert, prioritize it
                        if (![candidates containsObject:cand]) [candidates insertObject:cand atIndex:0];
                    }
                }
            }
        }
        
        // we prefer app groups with "Apps" in it, which indicate this app group is actually used by the store.
        for (NSString *group in candidates) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            NSURL *bundlePath = [path URLByAppendingPathComponent:@"Apps"];
            if ([NSFileManager.defaultManager fileExistsAtPath:bundlePath.path]) {
                // This will fail if LiveContainer is installed in both stores, but it should never be the case
                appGroupID = group;
                // Cache for next launch
                [lcUserDefaults setObject:group forKey:@"LCAppGroupID"];
                return;
            }
        }
        
        // if no "Apps" is found, we choose a valid group
        for (NSString *group in candidates) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            appGroupID = group;
            [lcUserDefaults setObject:group forKey:@"LCAppGroupID"];
            return;
        }
        
        // if no possibleAppGroup is found, we detect app group from entitlement file
        // Cache app group after importing cert so we don't have to analyze executable every launch
        NSString *cached = [lcUserDefaults objectForKey:@"LCAppGroupID"];
        if (cached && [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:cached]) {
            appGroupID = cached;
            return;
        }
        if(entGroups.count > 0) {
            appGroupID = [entGroups firstObject];
            [lcUserDefaults setObject:appGroupID forKey:@"LCAppGroupID"];
        }
    });
    return appGroupID;
}

+ (NSURL*) appGroupPath {
    static NSURL *appGroupPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *sharedPath = [self storeAppGroupPath];
        if (sharedPath) {
            appGroupPath = [sharedPath URLByAppendingPathComponent:@"T3CodeLive" isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:appGroupPath
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil];
        }
    });
    return appGroupPath;
}

+ (NSURL*) storeAppGroupPath {
    return [NSFileManager.defaultManager
        containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
}

+ (void)migrateLegacyT3Data {
    NSURL *sharedPath = [self storeAppGroupPath];
    NSURL *isolatedPath = [self appGroupPath];
    if (!sharedPath || !isolatedPath) {
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSUserDefaults *storeDefaults = [[NSUserDefaults alloc] initWithSuiteName:[self appGroupID]];
    NSArray *oldSchemes = [storeDefaults arrayForKey:@"LCGuestURLSchemes"];
    if ([oldSchemes isKindOfClass:NSArray.class]) {
        NSMutableArray *cleanSchemes = [oldSchemes mutableCopy];
        [cleanSchemes removeObject:@"t3code-livecontainer"];
        [storeDefaults setObject:cleanSchemes forKey:@"LCGuestURLSchemes"];
    }

    NSURL *legacyRoot = [sharedPath URLByAppendingPathComponent:@"LiveContainer" isDirectory:YES];
    NSURL *isolatedRoot = [isolatedPath URLByAppendingPathComponent:@"LiveContainer" isDirectory:YES];
    [fm createDirectoryAtURL:isolatedRoot withIntermediateDirectories:YES attributes:nil error:nil];

    // Move only T3's previous host data. Never move or delete the stock
    // LiveContainer root or another guest's data.
    NSURL *isolatedApps = [isolatedRoot URLByAppendingPathComponent:@"Applications" isDirectory:YES];
    NSString *hostBundleID = NSBundle.mainBundle.bundleIdentifier ?: @"codes.t3.t3code-live";
    NSArray<NSString *> *legacyBundleIDs = @[@"codes.t3.t3code-live", hostBundleID];
    for (NSString *legacyBundleID in legacyBundleIDs) {
        NSURL *legacyApp = [[legacyRoot URLByAppendingPathComponent:@"Applications" isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.app", legacyBundleID] isDirectory:YES];
        NSURL *isolatedApp = [isolatedApps URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.app", hostBundleID] isDirectory:YES];
        if (![fm fileExistsAtPath:legacyApp.path] || [fm fileExistsAtPath:isolatedApp.path]) {
            continue;
        }
        [fm createDirectoryAtURL:isolatedApps withIntermediateDirectories:YES attributes:nil error:nil];
        [fm moveItemAtURL:legacyApp toURL:isolatedApp error:nil];

        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:
            [isolatedApp URLByAppendingPathComponent:@"LCAppInfo.plist"]];
        NSString *dataUUID = info[@"LCDataUUID"];
        if (dataUUID.length > 0) {
            for (NSString *component in @[@"Data/Application", @"Data/AppGroup"]) {
                NSURL *legacyData = [[legacyRoot URLByAppendingPathComponent:component isDirectory:YES]
                    URLByAppendingPathComponent:dataUUID isDirectory:YES];
                NSURL *isolatedDataRoot = [isolatedRoot URLByAppendingPathComponent:component isDirectory:YES];
                NSURL *isolatedData = [isolatedDataRoot URLByAppendingPathComponent:dataUUID isDirectory:YES];
                if ([fm fileExistsAtPath:legacyData.path] && ![fm fileExistsAtPath:isolatedData.path]) {
                    [fm createDirectoryAtURL:isolatedDataRoot withIntermediateDirectories:YES attributes:nil error:nil];
                    [fm moveItemAtURL:legacyData toURL:isolatedData error:nil];
                }
            }
        }
        break;
    }
}

+ (NSString *)certificatePassword {
    NSUserDefaults* nud = NSUserDefaults.lcSharedDefaults ?: NSUserDefaults.standardUserDefaults;
    NSString *password = [nud objectForKey:@"LCCertificatePassword"];
    // T3: the app group may not be granted in every install scenario. Fall back to the
    // host app's own defaults so the certificate password is found regardless.
    if (!password && nud != NSUserDefaults.standardUserDefaults) {
        password = [NSUserDefaults.standardUserDefaults objectForKey:@"LCCertificatePassword"];
    }
    if (!password) {
        NSUserDefaults *storeDefaults = [[NSUserDefaults alloc] initWithSuiteName:[self appGroupID]];
        password = [storeDefaults objectForKey:@"LCCertificatePassword"];
    }
    return password;
}

+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode {
    void (^completionHandler)(BOOL) = ^(BOOL success) {
        // syscall(SYS_ptrace, PT_DENY_ATTACH, 0, 0, 0);
        __asm__ __volatile__ (
                              "mov x0, #31\n"
                              "mov x16, #26\n"
                              "svc #0x80"
                              );
        raise(SIGKILL);
    };
    
    if (!self.certificatePassword) {
        NSString *urlScheme = nil;
        NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
        if (!access(tsPath.UTF8String, F_OK)) {
            urlScheme = @"apple-magnifier://enable-jit?bundle-id=%@";
        }
        
        if(urlScheme) {
            NSURL *launchURL = [NSURL URLWithString:[NSString stringWithFormat:urlScheme, NSBundle.mainBundle.bundleIdentifier]];
            UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
            [application openURL:launchURL options:@{} completionHandler:completionHandler];
            return YES;
        }
    }

    int tries = 2;
    _LSOpenConfiguration *configuration = [[PrivClass(_LSOpenConfiguration) alloc] init];
    if(classicMode) {
        NSMutableDictionary* dict = [NSMutableDictionary new];
        dict[FBSOpenApplicationOptionKeyActivateAsClassic] = @(classicMode);
        configuration.frontBoardOptions = dict;
    }
    LSApplicationWorkspace* workspace = [PrivClass(LSApplicationWorkspace) defaultWorkspace];
    
    for (int i = 0; i < tries; i++) {
        [workspace openApplicationWithBundleIdentifier:NSUserDefaults.lcMainBundle.bundleIdentifier
                                         configuration:configuration
                                     completionHandler:^(BOOL success, NSError* error) {
            NSLog(@"success=%d error=%@", success, error);
            completionHandler(success);
        }];
    }
    return YES;
}

+ (BOOL)launchToGuestAppWithURL:(NSURL *)url {
    NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(![components.host isEqualToString:@"livecontainer-launch"]) return NO;

    NSString* launchBundleId = nil;
    NSString* openUrl = nil;
    NSString* containerFolderName = nil;
    for (NSURLQueryItem* queryItem in components.queryItems) {
        if ([queryItem.name isEqualToString:@"bundle-name"]) {
            launchBundleId = queryItem.value;
        } else if ([queryItem.name isEqualToString:@"open-url"]){
            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
            openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
            containerFolderName = queryItem.value;
        }
    }
    if(launchBundleId) {
        if (openUrl) {
            [lcUserDefaults setObject:openUrl forKey:@"launchAppUrlScheme"];
        }
        
        // Attempt to restart LiveContainer with the selected guest app
        [lcUserDefaults setObject:launchBundleId forKey:@"selected"];
        [lcUserDefaults setObject:containerFolderName forKey:@"selectedContainer"];
        bool isSharedApp = false;
        NSBundle *appBundle = [self findBundleWithBundleId:launchBundleId isSharedAppOut:&isSharedApp];
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
            [appBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
        NSUInteger classicMode = [appInfo[@"classicMode"] boolValue]
            ? [appInfo[@"LCClassicModeCache"][@"defaultClassicMode"] unsignedIntegerValue]
            : 0;
        return [self launchToGuestAppWithClassicMode:classicMode];
    }
    
    return NO;
}

+ (void)setWebPageUrlForNextLaunch:(NSString*) urlString {
    [lcUserDefaults setObject:urlString forKey:@"webPageToOpen"];
}

+ (NSURL*)containerLockPath {
    static dispatch_once_t once;
    static NSURL *infoPath;
    
    dispatch_once(&once, ^{
        infoPath = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer/containerLock.plist"];
    });
    return infoPath;
}

+ (BOOL)isLCSchemeInUse:(NSString*)lc {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return NO;
    }
    
    NSNumber* num57 = info[lc];
    if(![num57 isKindOfClass:NSNumber.class]) {
        return NO;
    }
    
    uint64_t val57 = [num57 longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno != ESRCH;
}

+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return nil;
    }
    
    NSDictionary* appUsageInfo = info[folderName];
    if (!appUsageInfo) {
        return nil;
    }
    uint64_t val57 = [appUsageInfo[@"auditToken57"] longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno==ESRCH ? nil : appUsageInfo[@"runningLC"];
}

// lc can be something like livecontainer or livecontainer2.liveprocess, such that one LC can jump to another LC hosting the multitask app when user presses run while it's running
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57 {
    NSURL* infoPath = [self containerLockPath];
    
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        info = [NSMutableDictionary new];
    }
    
    if(val57 == 0) {
        audit_token_t token;
        mach_msg_type_number_t size = TASK_AUDIT_TOKEN_COUNT;
        
        kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &size);
        if (kr != KERN_SUCCESS) {
            NSLog(@"Error getting task audit_token");
        }
        val57 = token.val[7] | ((uint64_t)token.val[5] << 32);
    }
    info[folderName] = @{
        @"runningLC": lc,
        @"auditToken57": @(val57)
    };
    
    info[lc] = @(val57);

    [info writeBinToFile:infoPath.path atomically:YES];
}

// move app data to private folder to prevent 0xdead10cc https://forums.developer.apple.com/forums/thread/126438
// This method is here for backward compatability, 0xdead10cc is already resolved.
+ (void)moveSharedAppFolderBack {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *libraryPathUrl = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *docPathUrl = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSError *error;
    NSString *sharedAppDataFolderPath = [libraryPathUrl.path stringByAppendingPathComponent:@"SharedDocuments"];
    if(![fm fileExistsAtPath:sharedAppDataFolderPath]){
        return;
    }
    // move all apps in shared folder back
    NSArray<NSString *> * sharedDataFoldersToMove = [fm contentsOfDirectoryAtPath:sharedAppDataFolderPath error:&error];
    
    // something went wrong with app group
    if(!appGroupFolder && sharedDataFoldersToMove.count > 0) {
        [lcUserDefaults setObject:@"LiveContainer was unable to move the data of shared app back because LiveContainer cannot access app group. Please check JITLess diagnose page in LiveContainer settings for more information." forKey:@"error"];
        return;
    }
    
    for(int i = 0; i < [sharedDataFoldersToMove count]; ++i) {
        NSString* destPath = [appGroupFolder.path stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", sharedDataFoldersToMove[i]]];
        if([fm fileExistsAtPath:destPath]) {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:[docPathUrl.path stringByAppendingPathComponent:[NSString stringWithFormat:@"FOLDER_EXISTS_AT_APP_GROUP_%@", sharedDataFoldersToMove[i]]]
             error:&error
            ];
            
        } else {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:destPath
             error:&error
            ];
        }
    }
    
}

+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut {
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, bundleId];
    NSBundle *appBundle;
    if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        appBundle = [[NSBundle alloc] initWithPath:bundlePath];
    }

    // not found locally, let's look for the app in shared folder
    if (!appBundle) {
        appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
        
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, bundleId];
        if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
            appBundle = [[NSBundle alloc] initWithPath:bundlePath];
        }
        if(appBundle) {
            *isSharedAppOut = true;
        }
    } else {
        *isSharedAppOut = false;
    }
    return appBundle;
}

// This method is here for backward compatability, preferences is direcrly saved to app's preference folder.
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID {
    NSFileManager* fm = [[NSFileManager alloc] init];
    NSError* error1;
    
    NSDictionary* preferences = [lcUserDefaults objectForKey:dataUUID];
    if(!preferences) {
        return;
    }
    
    [fm createDirectoryAtPath:plistLocationTo withIntermediateDirectories:YES attributes:@{} error:&error1];
    for(NSString* identifier in preferences) {
        NSDictionary* preference = preferences[identifier];
        NSString *itemPath = [plistLocationTo stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", identifier]];
        if([preference count] == 0) {
            // Attempt to delete the file
            [fm removeItemAtPath:itemPath error:&error1];
            continue;
        }
        [preference writeToFile:itemPath atomically:YES];
    }
    [lcUserDefaults removeObjectForKey:dataUUID];
}

+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId {
    // find app's default container
    NSURL* appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder.path, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    return infoDict[@"LCDataUUID"];
}

+ (NSArray<NSString*>*)lcUnorderedUrlSchemes {
    NSArray<NSString *> *defaultSchemes = @[@"t3code-livecontainer", @"livecontainer", @"livecontainer2", @"livecontainer3"];
    return defaultSchemes;
}

+ (NSArray<NSString*>*)lcUrlSchemes {
    NSArray<NSString *> *defaultSchemes = [self lcUnorderedUrlSchemes];
    NSSet<NSString *> *allowedSchemes = [NSSet setWithArray:defaultSchemes];
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    id savedValue = [NSUserDefaults.lcSharedDefaults objectForKey:@"LCMultiLaunchPriority"];
    if([savedValue isKindOfClass:NSArray.class]) {
        for(id value in (NSArray *)savedValue) {
            if(![value isKindOfClass:NSString.class]) {
                continue;
            }

            NSString *scheme = [(NSString *)value lowercaseString];
            if(![allowedSchemes containsObject:scheme] || [result containsObject:scheme]) {
                continue;
            }

            [result addObject:scheme];
        }
    }

    for(NSString *scheme in defaultSchemes) {
        if(![result containsObject:scheme]) {
            [result addObject:scheme];
        }
    }

    return result;
}
@end
