//
//  AppDelegate.swift
//  p0ng tvOS
//
//  Created by Ryan Jennings on 2018-05-12.
//  Copyright © 2018 Micrantha Software. All rights reserved.
//

import UIKit

@UIApplicationMain
class AppDelegate: BaseAppDelegate {

    func applicationDidFinishLaunching(_ application: UIApplication) {        
        self.window = UIWindow(frame: UIScreen.main.bounds)
        
        let viewController = MenuController(delegate: self, nibName: "MenuController", bundle:nil)
        
        viewController.appDelegate = self
        
        self.viewControllers.append(viewController)
        
        self.window?.rootViewController = viewController
        self.window?.makeKeyAndVisible()
    }
}

