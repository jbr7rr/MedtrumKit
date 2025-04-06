//
//  IdentifiableClass.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 06/04/2025.
//


import Foundation


protocol IdentifiableClass: AnyObject {
    static var className: String { get }
}


extension IdentifiableClass {
    static var className: String {
        return NSStringFromClass(self).components(separatedBy: ".").last!
    }
}
