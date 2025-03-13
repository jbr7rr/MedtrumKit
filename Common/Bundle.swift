//
//  Bundle.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 13/03/2025.
//

import Foundation

extension Bundle {
    var bundleDisplayName: String {
        return object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
    }
}
