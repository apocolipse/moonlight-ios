//  MainFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/17/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import ImageIO;

#import "MainFrameViewController.h"
#import "CryptoManager.h"
#import "HttpManager.h"
#import "Connection.h"
#import "StreamManager.h"
#import "Utils.h"
#import "UIComputerView.h"
#import "UIAppView.h"
#import "SettingsViewController.h"
#import "DataManager.h"
#import "TemporarySettings.h"
#import "WakeOnLanManager.h"
#import "AppListResponse.h"
#import "ServerInfoResponse.h"
#import "StreamFrameViewController.h"
#import "LoadingFrameViewController.h"
#import "ComputerScrollView.h"
#import "TemporaryApp.h"
#import "IdManager.h"

@implementation MainFrameViewController {
    NSOperationQueue* _opQueue;
    TemporaryHost* _selectedHost;
    NSString* _uniqueId;
    NSData* _cert;
    DiscoveryManager* _discMan;
    AppAssetManager* _appManager;
    StreamConfiguration* _streamConfig;
    UIAlertController* _pairAlert;
#if TARGET_OS_IOS
    UIScrollView* hostScrollView;
#elif TARGET_OS_TV
    ComputerScrollView* hostScrollView;
#endif
    int currentPosition;
    NSArray* _sortedAppList;
    NSCache* _boxArtCache;
}
static NSMutableSet* hostList;

- (void)showPIN:(NSString *)PIN {
    dispatch_async(dispatch_get_main_queue(), ^{
        _pairAlert = [UIAlertController alertControllerWithTitle:@"Pairing"
                                                         message:[NSString stringWithFormat:@"Enter the following PIN on the host machine: %@", PIN]
                                                  preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:_pairAlert animated:YES completion:nil];
    });
}

- (void)pairFailed:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_pairAlert dismissViewControllerAnimated:YES completion:nil];
        _pairAlert = [UIAlertController alertControllerWithTitle:@"Pairing Failed"
                                                         message:message
                                                  preferredStyle:UIAlertControllerStyleAlert];
        [_pairAlert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
        [self presentViewController:_pairAlert animated:YES completion:nil];
        
        [_discMan startDiscovery];
        [self hideLoadingFrame];
    });
}

- (void)pairSuccessful {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_pairAlert dismissViewControllerAnimated:YES completion:nil];
        [_discMan startDiscovery];
        [self alreadyPaired];
    });
}

- (void)alreadyPaired {
    BOOL usingCachedAppList = false;
    
    // Capture the host here because it can change once we
    // leave the main thread
    TemporaryHost* host = _selectedHost;
    
    if ([host.appList count] > 0) {
        usingCachedAppList = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (host != _selectedHost) {
                return;
            }
            
            _computerNameButton.title = host.name;
            [self.navigationController.navigationBar setNeedsLayout];
            
            [self updateAppsForHost:host];
            [self hideLoadingFrame];
        });
    }
    Log(LOG_I, @"Using cached app list: %d", usingCachedAppList);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager* hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:_uniqueId deviceName:deviceName cert:_cert];
        
        // Exempt this host from discovery while handling the applist query
        [_discMan removeHostFromDiscovery:host];
        
        // Try up to 5 times to get the app list
        AppListResponse* appListResp;
        for (int i = 0; i < 5; i++) {
            appListResp = [[AppListResponse alloc] init];
            [hMan executeRequestSynchronously:[HttpRequest requestForResponse:appListResp withUrlRequest:[hMan newAppListRequest]]];
            if (appListResp == nil || ![appListResp isStatusOk] || [appListResp getAppList] == nil) {
                Log(LOG_W, @"Failed to get applist on try %d: %@", i, appListResp.statusMessage);
                
                // Wait for one second then retry
                [NSThread sleepForTimeInterval:1];
            }
            else {
                Log(LOG_I, @"App list successfully retreived - took %d tries", i);
                break;
            }
        }
        
        [_discMan addHostToDiscovery:host];

        if (appListResp == nil || ![appListResp isStatusOk] || [appListResp getAppList] == nil) {
            Log(LOG_W, @"Failed to get applist: %@", appListResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingFrame];
                
                if (host != _selectedHost) {
                    return;
                }
                
                UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:@"Fetching App List Failed"
                                                                                      message:@"The connection to the PC was interrupted."
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [applistAlert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
                [self presentViewController:applistAlert animated:YES completion:nil];
                host.online = NO;
                [self showHostSelectionView];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateApplist:[appListResp getAppList] forHost:host];

                if (host != _selectedHost) {
                    return;
                }
                
                _computerNameButton.title = host.name;
                [self.navigationController.navigationBar setNeedsLayout];
                
                [self updateAppsForHost:host];
                [_appManager stopRetrieving];
                [_appManager retrieveAssetsFromHost:host];
                [self hideLoadingFrame];
            });
        }
    });
}

- (void) updateApplist:(NSSet*) newList forHost:(TemporaryHost*)host {
    DataManager* database = [[DataManager alloc] init];
    
    for (TemporaryApp* app in newList) {
        BOOL appAlreadyInList = NO;
        for (TemporaryApp* savedApp in host.appList) {
            if ([app.id isEqualToString:savedApp.id]) {
                savedApp.name = app.name;
                savedApp.isRunning = app.isRunning;
                appAlreadyInList = YES;
                break;
            }
        }
        if (!appAlreadyInList) {
            app.host = host;
            [host.appList addObject:app];
        }
    }
    
    BOOL appWasRemoved;
    do {
        appWasRemoved = NO;
        
        for (TemporaryApp* app in host.appList) {
            appWasRemoved = YES;
            for (TemporaryApp* mergedApp in newList) {
                if ([mergedApp.id isEqualToString:app.id]) {
                    appWasRemoved = NO;
                    break;
                }
            }
            if (appWasRemoved) {
                // Removing the app mutates the list we're iterating (which isn't legal).
                // We need to jump out of this loop and restart enumeration.
                
                [host.appList removeObject:app];
                
                // It's important to remove the app record from the database
                // since we'll have a constraint violation now that appList
                // doesn't have this app in it.
                [database removeApp:app];
                
                break;
            }
        }
        
        // Keep looping until the list is no longer being mutated
    } while (appWasRemoved);

    [database updateAppsForExistingHost:host];
}

- (void)showHostSelectionView {
    [_appManager stopRetrieving];
    _selectedHost = nil;
    _computerNameButton.title = @"No Host Selected";
    [self.collectionView reloadData];
    [self.view addSubview:hostScrollView];
}

- (void) receivedAssetForApp:(TemporaryApp*)app {
    // Update the box art cache now so we don't have to do it
    // on the main thread
    [self updateBoxArtCacheForApp:app];
    
    DataManager* dataManager = [[DataManager alloc] init];
    [dataManager updateIconForExistingApp: app];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)displayDnsFailedDialog {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Network Error"
                                                                   message:@"Failed to resolve host."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) hostClicked:(TemporaryHost *)host view:(UIView *)view {
    // Treat clicks on offline hosts to be long clicks
    // This shows the context menu with wake, delete, etc. rather
    // than just hanging for a while and failing as we would in this
    // code path.
    if (!host.online && view != nil) {
        [self hostLongClicked:host view:view];
        return;
    }
    
    Log(LOG_D, @"Clicked host: %@", host.name);
    _selectedHost = host;
    [self disableNavigation];
    
    // If we are online, paired, and have a cached app list, skip straight
    // to the app grid without a loading frame. This is the fast path that users
    // should hit most.
    if (host.online && host.pairState == PairStatePaired && host.appList.count > 0) {
        [self alreadyPaired];
        return;
    }
    
    [self showLoadingFrame];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        HttpManager* hMan = [[HttpManager alloc] initWithHost:host.activeAddress uniqueId:_uniqueId deviceName:deviceName cert:_cert];
        ServerInfoResponse* serverInfoResp = [[ServerInfoResponse alloc] init];
        
        // Exempt this host from discovery while handling the serverinfo request
        [_discMan removeHostFromDiscovery:host];
        [hMan executeRequestSynchronously:[HttpRequest requestForResponse:serverInfoResp withUrlRequest:[hMan newServerInfoRequest]
                                           fallbackError:401 fallbackRequest:[hMan newHttpServerInfoRequest]]];
        [_discMan addHostToDiscovery:host];
        
        if (serverInfoResp == nil || ![serverInfoResp isStatusOk]) {
            Log(LOG_W, @"Failed to get server info: %@", serverInfoResp.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideLoadingFrame];
                
                if (host != _selectedHost) {
                    return;
                }
                
                UIAlertController* applistAlert = [UIAlertController alertControllerWithTitle:@"Fetching Server Info Failed"
                                                                                      message:@"The connection to the PC was interrupted."
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [applistAlert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
                [self presentViewController:applistAlert animated:YES completion:nil];
                host.online = NO;
                [self showHostSelectionView];
            });
        } else {
            Log(LOG_D, @"server info pair status: %@", [serverInfoResp getStringTag:@"PairStatus"]);
            if ([[serverInfoResp getStringTag:@"PairStatus"] isEqualToString:@"1"]) {
                Log(LOG_I, @"Already Paired");
                [self alreadyPaired];
            } else {
                Log(LOG_I, @"Trying to pair");
                // Polling the server while pairing causes the server to screw up
                [_discMan stopDiscoveryBlocking];
                PairManager* pMan = [[PairManager alloc] initWithManager:hMan andCert:_cert callback:self];
                [_opQueue addOperation:pMan];
            }
        }
    });
}

- (void)hostLongClicked:(TemporaryHost *)host view:(UIView *)view {
    Log(LOG_D, @"Long clicked host: %@", host.name);
    UIAlertController* longClickAlert = [UIAlertController alertControllerWithTitle:host.name message:@"" preferredStyle:UIAlertControllerStyleActionSheet];
    if (!host.online) {
        [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Wake" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            UIAlertController* wolAlert = [UIAlertController alertControllerWithTitle:@"Wake On Lan" message:@"" preferredStyle:UIAlertControllerStyleAlert];
            [wolAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            if (host.pairState != PairStatePaired) {
                wolAlert.message = @"Cannot wake host because you are not paired";
            } else if (host.mac == nil || [host.mac isEqualToString:@"00:00:00:00:00:00"]) {
                wolAlert.message = @"Host MAC unknown, unable to send WOL Packet";
            } else {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [WakeOnLanManager wakeHost:host];
                });
                wolAlert.message = @"Sent WOL Packet";
            }
            [self presentViewController:wolAlert animated:YES completion:nil];
        }]];
    }
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Remove Host" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [_discMan removeHostFromDiscovery:host];
        DataManager* dataMan = [[DataManager alloc] init];
        [dataMan removeHost:host];
        @synchronized(hostList) {
            [hostList removeObject:host];
            [self updateAllHosts:[hostList allObjects]];
        }
        
    }]];
    [longClickAlert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    // these two lines are required for iPad support of UIAlertSheet
    longClickAlert.popoverPresentationController.sourceView = view;
    
    longClickAlert.popoverPresentationController.sourceRect = CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 2.0, 1.0, 1.0); // center of the view
    [self presentViewController:longClickAlert animated:YES completion:^{
        [self updateHosts];
    }];
}

- (void) addHostClicked {
    Log(LOG_D, @"Clicked add host");
    [self showLoadingFrame];
    UIAlertController* alertController = [UIAlertController alertControllerWithTitle:@"Host Address" message:@"Please enter a hostname or IP address" preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
        NSString* hostAddress = ((UITextField*)[[alertController textFields] objectAtIndex:0]).text;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [_discMan discoverHost:hostAddress withCallback:^(TemporaryHost* host, NSString* error){
                if (host != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @synchronized(hostList) {
                            [hostList addObject:host];
                        }
                        [self updateHosts];
                    });
                } else {
                    UIAlertController* hostNotFoundAlert = [UIAlertController alertControllerWithTitle:@"Add Host" message:error preferredStyle:UIAlertControllerStyleAlert];
                    [hostNotFoundAlert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self presentViewController:hostNotFoundAlert animated:YES completion:nil];
                    });
                }
            }];});
    }]];
    [alertController addTextFieldWithConfigurationHandler:nil];
    [self hideLoadingFrame];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void) appClicked:(TemporaryApp *)app {
    Log(LOG_D, @"Clicked app: %@", app.name);
    _streamConfig = [[StreamConfiguration alloc] init];
    _streamConfig.host = app.host.activeAddress;
    _streamConfig.appID = app.id;
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* streamSettings = [dataMan getSettings];
    
    _streamConfig.frameRate = [streamSettings.framerate intValue];
    _streamConfig.bitRate = [streamSettings.bitrate intValue];
    _streamConfig.height = [streamSettings.height intValue];
    _streamConfig.width = [streamSettings.width intValue];
    
    [_appManager stopRetrieving];
    
    if (currentPosition != FrontViewPositionLeft) {
        [[self revealViewController] revealToggle:self];
    }
    
    TemporaryApp* currentApp = [self findRunningApp:app.host];
    if (currentApp != nil) {
        UIAlertController* alertController = [UIAlertController
                                              alertControllerWithTitle: app.name
                                              message: [app.id isEqualToString:currentApp.id] ? @"" : [NSString stringWithFormat:@"%@ is currently running", currentApp.name]preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction
                                    actionWithTitle:[app.id isEqualToString:currentApp.id] ? @"Resume App" : @"Resume Running App" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
                                        Log(LOG_I, @"Resuming application: %@", currentApp.name);
                                        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
                                    }]];
        [alertController addAction:[UIAlertAction actionWithTitle:
                                    [app.id isEqualToString:currentApp.id] ? @"Quit App" : @"Quit Running App and Start" style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action){
                                        Log(LOG_I, @"Quitting application: %@", currentApp.name);
                                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                            HttpManager* hMan = [[HttpManager alloc] initWithHost:app.host.activeAddress uniqueId:_uniqueId deviceName:deviceName cert:_cert];
                                            HttpResponse* quitResponse = [[HttpResponse alloc] init];
                                            HttpRequest* quitRequest = [HttpRequest requestForResponse: quitResponse withUrlRequest:[hMan newQuitAppRequest]];
                                            
                                            // Exempt this host from discovery while handling the quit operation
                                            [_discMan removeHostFromDiscovery:app.host];
                                            [hMan executeRequestSynchronously:quitRequest];
                                            [_discMan addHostToDiscovery:app.host];
                                            
                                            UIAlertController* alert;
                                            
                                            // If it fails, display an error and stop the current operation
                                            if (quitResponse.statusCode != 200) {
                                               alert = [UIAlertController alertControllerWithTitle:@"Quitting App Failed"
                                                                                      message:@"Failed to quit app. If this app was started by "
                                                        "another device, you'll need to quit from that device."
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                                            }
                                            // If it succeeds and we're to start streaming, segue to the stream and return
                                            else if (![app.id isEqualToString:currentApp.id]) {
                                                currentApp.isRunning = NO;
                                                
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    [self updateAppsForHost:app.host];
                                                    [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
                                                });
                                                
                                                return;
                                            }
                                            // Otherwise, display a dialog to notify the user that the app was quit
                                            else {
                                                currentApp.isRunning = NO;
                                                
                                                alert = [UIAlertController alertControllerWithTitle:@"Quitting App"
                                                                                            message:@"The app was quit successfully."
                                                                                     preferredStyle:UIAlertControllerStyleAlert];
                                            }
                                            
                                            [alert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDestructive handler:nil]];
                                            dispatch_async(dispatch_get_main_queue(), ^{
                                                [self updateAppsForHost:app.host];
                                                [self presentViewController:alert animated:YES completion:nil];
                                            });
                                        });
                                    }]];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    } else {
        [self performSegueWithIdentifier:@"createStreamFrame" sender:nil];
    }
}

- (TemporaryApp*) findRunningApp:(TemporaryHost*)host {
    for (TemporaryApp* app in host.appList) {
        if (app.isRunning) {
            return app;
        }
    }
    return nil;
}

- (void)revealController:(SWRevealViewController *)revealController didMoveToPosition:(FrontViewPosition)position {
    // If we moved back to the center position, we should save the settings
    if (position == FrontViewPositionLeft) {
        [(SettingsViewController*)[revealController rearViewController] saveSettings];
    }
    currentPosition = position;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.destinationViewController isKindOfClass:[StreamFrameViewController class]]) {
        StreamFrameViewController* streamFrame = segue.destinationViewController;
        streamFrame.streamConfig = _streamConfig;
    }
}

- (void) showLoadingFrame {
    LoadingFrameViewController* loadingFrame = [self.storyboard instantiateViewControllerWithIdentifier:@"loadingFrame"];
    [self.navigationController presentViewController:loadingFrame animated:YES completion:nil];
}

- (void) hideLoadingFrame {
    [self dismissViewControllerAnimated:YES completion:nil];
    [self enableNavigation];
}
#if TARGET_OS_IOS
#elif TARGET_OS_TV
- (void)pushSettings:(id)sender {
  UIStoryboard *mainStoryboard = [UIStoryboard storyboardWithName:@"tvosStory" bundle:nil];
  SettingsViewController *vc = [mainStoryboard instantiateViewControllerWithIdentifier:@"settingsViewController"];
  [self.navigationController pushViewController:vc animated:YES];
}

#endif

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Set the side bar button action. When it's tapped, it'll show the sidebar.
#if TARGET_OS_IOS
    [_limelightLogoButton addTarget:self.revealViewController action:@selector(revealToggle:) forControlEvents:UIControlEventTouchDown];
#elif TARGET_OS_TV
    [_limelightLogoButton addTarget:self action:@selector(pushSettings:) forControlEvents:UIControlEventPrimaryActionTriggered];
#endif
    // Set the host name button action. When it's tapped, it'll show the host selection view.
    [_computerNameButton setTarget:self];
    [_computerNameButton setAction:@selector(showHostSelectionView)];
    
    // Set the gesture
    [self.view addGestureRecognizer:self.revealViewController.panGestureRecognizer];
    
    // Get callbacks associated with the viewController
    [self.revealViewController setDelegate:self];
    
    // Set the current position to the center
    currentPosition = FrontViewPositionLeft;
    
    // Set up crypto
    [CryptoManager generateKeyPairUsingSSl];
    _uniqueId = [IdManager getUniqueId];
    _cert = [CryptoManager readCertFromFile];

    _appManager = [[AppAssetManager alloc] initWithCallback:self];
    _opQueue = [[NSOperationQueue alloc] init];
    
    // Only initialize the host picker list once
    if (hostList == nil) {
        hostList = [[NSMutableSet alloc] init];
    }
    
    _boxArtCache = [[NSCache alloc] init];
    
    [self setAutomaticallyAdjustsScrollViewInsets:NO];
    
    hostScrollView = [[ComputerScrollView alloc] init];
    hostScrollView.frame = CGRectMake(0, self.navigationController.navigationBar.frame.origin.y + self.navigationController.navigationBar.frame.size.height, self.view.frame.size.width, self.view.frame.size.height / 2);
    [hostScrollView setShowsHorizontalScrollIndicator:NO];
    hostScrollView.delaysContentTouches = NO;
    
    UIButton* pullArrow = [[UIButton alloc] init];
    [pullArrow setImage:[UIImage imageNamed:@"PullArrow"] forState:UIControlStateNormal];
    [pullArrow sizeToFit];
    pullArrow.frame = CGRectMake(0,
                                 self.collectionView.frame.size.height / 2 - pullArrow.frame.size.height / 2 - self.navigationController.navigationBar.frame.size.height,
                                 pullArrow.frame.size.width,
                                 pullArrow.frame.size.height);
    [self.view addSubview:pullArrow];
    
    
    self.collectionView.delaysContentTouches = NO;
    self.collectionView.allowsMultipleSelection = NO;
#if TARGET_OS_IOS
  self.collectionView.multipleTouchEnabled = NO;
#elif TARGET_OS_TV
#endif
    [self retrieveSavedHosts];
    _discMan = [[DiscoveryManager alloc] initWithHosts:[hostList allObjects] andCallback:self];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(handleReturnToForeground)
                                                 name: UIApplicationWillEnterForegroundNotification
                                               object: nil];
    
    [self updateHosts];
    [self.view addSubview:hostScrollView];
}

-(void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void)handleReturnToForeground
{
    // This will refresh the applist
    if (_selectedHost != nil) {
        [self hostClicked:_selectedHost view:nil];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
    
    // Hide 1px border line
    UIImage* fakeImage = [[UIImage alloc] init];
    [self.navigationController.navigationBar setShadowImage:fakeImage];
    [self.navigationController.navigationBar setBackgroundImage:fakeImage forBarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
    
    [_discMan startDiscovery];
    
    [self handleReturnToForeground];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    // when discovery stops, we must create a new instance because you cannot restart an NSOperation when it is finished
    [_discMan stopDiscovery];
    
    // Purge the box art cache
    [_boxArtCache removeAllObjects];
}

- (void) retrieveSavedHosts {
    DataManager* dataMan = [[DataManager alloc] init];
    NSArray* hosts = [dataMan getHosts];
    @synchronized(hostList) {
        [hostList addObjectsFromArray:hosts];
        
        // Initialize the non-persistent host state
        for (TemporaryHost* host in hostList) {
            if (host.activeAddress == nil) {
                host.activeAddress = host.localAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.externalAddress;
            }
            if (host.activeAddress == nil) {
                host.activeAddress = host.address;
            }
        }
    }
}
#if TARGET_OS_IOS
#elif TARGET_OS_TV
- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator
{
    UIView *next =context.nextFocusedView;
    UIView *prev =context.previouslyFocusedView;
    if ([next isMemberOfClass:[UIButton class]]) {
      next.layer.shadowColor = [[UIColor greenColor] CGColor];
      prev.layer.shadowColor = [[UIColor blackColor] CGColor];
    }
}
#endif

- (void) updateAllHosts:(NSArray *)hosts {
    dispatch_async(dispatch_get_main_queue(), ^{
        Log(LOG_D, @"New host list:");
        for (TemporaryHost* host in hosts) {
            Log(LOG_D, @"Host: \n{\n\t name:%@ \n\t address:%@ \n\t localAddress:%@ \n\t externalAddress:%@ \n\t uuid:%@ \n\t mac:%@ \n\t pairState:%d \n\t online:%d \n\t activeAddress:%@ \n}", host.name, host.address, host.localAddress, host.externalAddress, host.uuid, host.mac, host.pairState, host.online, host.activeAddress);
        }
        @synchronized(hostList) {
            [hostList removeAllObjects];
            [hostList addObjectsFromArray:hosts];
        }
        [self updateHosts];
    });
}

- (void)updateHosts {
    Log(LOG_I, @"Updating hosts...");
    [[hostScrollView subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
    UIComputerView* addComp = [[UIComputerView alloc] initForAddWithCallback:self];
    UIComputerView* compView;
    float prevEdge = -1;
    @synchronized (hostList) {
        // Sort the host list in alphabetical order
        NSArray* sortedHostList = [[hostList allObjects] sortedArrayUsingSelector:@selector(compareName:)];
        for (TemporaryHost* comp in sortedHostList) {
            compView = [[UIComputerView alloc] initWithComputer:comp andCallback:self];
            compView.center = CGPointMake([self getCompViewX:compView addComp:addComp prevEdge:prevEdge], hostScrollView.frame.size.height / 2);
            prevEdge = compView.frame.origin.x + compView.frame.size.width;
            [hostScrollView addSubview:compView];
        }
    }
    
    prevEdge = [self getCompViewX:addComp addComp:addComp prevEdge:prevEdge];
    addComp.center = CGPointMake(prevEdge, hostScrollView.frame.size.height / 2);
    
    [hostScrollView addSubview:addComp];
    [hostScrollView setContentSize:CGSizeMake(prevEdge + addComp.frame.size.width, hostScrollView.frame.size.height)];
}

- (float) getCompViewX:(UIComputerView*)comp addComp:(UIComputerView*)addComp prevEdge:(float)prevEdge {
    if (prevEdge == -1) {
        return hostScrollView.frame.origin.x + comp.frame.size.width / 2 + addComp.frame.size.width / 2;
    } else {
        return prevEdge + addComp.frame.size.width / 2  + comp.frame.size.width / 2;
    }
}

// This function forces immediate decoding of the UIImage, rather
// than the default lazy decoding that results in janky scrolling.
+ (UIImage*) loadBoxArtForCaching:(TemporaryApp*)app {
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)app.image, NULL);
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCacheImmediately: (id)kCFBooleanTrue});
    
    UIImage *boxArt = [UIImage imageWithCGImage:cgImage];
    
    CGImageRelease(cgImage);
    CFRelease(source);
    
    return boxArt;
}

- (void) updateBoxArtCacheForApp:(TemporaryApp*)app {
    if (app.image == nil) {
        [_boxArtCache removeObjectForKey:app];
    }
    else if ([_boxArtCache objectForKey:app] == nil) {
        [_boxArtCache setObject:[MainFrameViewController loadBoxArtForCaching:app] forKey:app];
    }
}

- (void) updateAppsForHost:(TemporaryHost*)host {
    if (host != _selectedHost) {
        Log(LOG_W, @"Mismatched host during app update");
        return;
    }
    
    _sortedAppList = [host.appList allObjects];
    _sortedAppList = [_sortedAppList sortedArrayUsingSelector:@selector(compareName:)];
    
    // Split the sorted array in half to allow 2 jobs to process app assets at once
    NSArray *firstHalf;
    NSArray *secondHalf;
    NSRange range;
    
    range.location = 0;
    range.length = [_sortedAppList count] / 2;
    
    firstHalf = [_sortedAppList subarrayWithRange:range];
    
    range.location = range.length;
    range.length = [_sortedAppList count] - range.length;
    
    secondHalf = [_sortedAppList subarrayWithRange:range];
    
    // Start 2 jobs
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (TemporaryApp* app in firstHalf) {
            [self updateBoxArtCacheForApp:app];
        }
    });
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (TemporaryApp* app in secondHalf) {
            [self updateBoxArtCacheForApp:app];
        }
    });
    
    [hostScrollView removeFromSuperview];
    [self.collectionView reloadData];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell* cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"AppCell" forIndexPath:indexPath];
    
    TemporaryApp* app = _sortedAppList[indexPath.row];
    UIAppView* appView = [[UIAppView alloc] initWithApp:app cache:_boxArtCache andCallback:self];
    [appView updateAppImage];
    
    if (appView.bounds.size.width > 10.0) {
        CGFloat scale = cell.bounds.size.width / appView.bounds.size.width;
        [appView setCenter:CGPointMake(appView.bounds.size.width / 2 * scale, appView.bounds.size.height / 2 * scale)];
        appView.transform = CGAffineTransformMakeScale(scale, scale);
    }
    
    [cell.subviews.firstObject removeFromSuperview]; // Remove a view that was previously added
    [cell addSubview:appView];

    
    UIBezierPath *shadowPath = [UIBezierPath bezierPathWithRect:cell.bounds];
    cell.layer.masksToBounds = NO;
    cell.layer.shadowColor = [UIColor blackColor].CGColor;
    cell.layer.shadowOffset = CGSizeMake(1.0f, 5.0f);
    cell.layer.shadowOpacity = 0.5f;
    cell.layer.shadowPath = shadowPath.CGPath;
    
    cell.layer.borderColor = [[UIColor colorWithRed:0 green:0 blue:0 alpha:0.3f] CGColor];
    cell.layer.borderWidth = 1;

#if TARGET_OS_IOS
    cell.exclusiveTouch = YES;
#elif TARGET_OS_TV
#endif
    return cell;
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1; // App collection only
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (_selectedHost != nil) {
        return _selectedHost.appList.count;
    }
    else {
        return 0;
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (void) disableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = NO;
}

- (void) enableNavigation {
    self.navigationController.navigationBar.topItem.rightBarButtonItem.enabled = YES;
}
#if TARGET_OS_IOS
#elif TARGET_OS_TV
- (BOOL)collectionView:(UICollectionView *)collectionView canFocusItemAtIndexPath:(NSIndexPath *)indexPath {
    return TRUE;
}

- (BOOL)collectionView:(UICollectionView *)colView shouldUpdateFocusInContext:(nonnull UICollectionViewFocusUpdateContext *)context {
    return YES;
}

-(void)collectionView:(UICollectionView *)collectionView didUpdateFocusInContext:(nonnull UICollectionViewFocusUpdateContext *)context withAnimationCoordinator:(nonnull UIFocusAnimationCoordinator *)coordinator {
  
  
    UIView *next = context.nextFocusedView;
    UIView *prev = context.previouslyFocusedView;
  
    //UIAppView *app = next.subviews[0];
    next.backgroundColor = [UIColor greenColor];
    next.layer.shadowColor = [UIColor greenColor].CGColor;
  
    prev.backgroundColor = [UIColor clearColor];
    prev.layer.shadowColor = [UIColor blackColor].CGColor;
  
    //Log(LOG_I, @"App : %@",[app getApp].name);
  
}

-(BOOL)collectionView:(UICollectionView *)collectionView shouldSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

-(void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell* cell = (UICollectionViewCell*)[collectionView cellForItemAtIndexPath:indexPath];
  
    UIAppView *app = cell.subviews[0];
    [self appClicked:[app getApp]];
}

- (void)collectionView:(UICollectionView *)colView didHighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell* cell = [colView cellForItemAtIndexPath:indexPath];
    Log(LOG_I, @"Highlight row:%d, section:%d",indexPath.row,indexPath.section);
  
    UIAppView *app = cell.subviews[0];
    Log(LOG_I, @"App : %@",[app getApp].name);
  
    //set color with animation
    [UIView animateWithDuration:0.1
                          delay:0
                        options:(UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
                        [cell setBackgroundColor:[UIColor colorWithRed:232/255.0f green:232/255.0f blue:232/255.0f alpha:1]];
                     }
                     completion:nil];
}

- (void)collectionView:(UICollectionView *)colView  didUnhighlightItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell* cell = [colView cellForItemAtIndexPath:indexPath];
    //set color with animation
    [UIView animateWithDuration:0.1
                          delay:0
                        options:(UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
                        [cell setBackgroundColor:[UIColor clearColor]];
                     }
                     completion:nil ];
}

- (BOOL)collectionView:(UICollectionView *)collectionView shouldHighlightItemAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}
#endif
@end
