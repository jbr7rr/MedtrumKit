//
//  NibLoadable.swift
//  MedtrumKit
//
//  Created by Bastiaan Verhaar on 06/04/2025.
//


import UIKit


protocol NibLoadable: IdentifiableClass {
    static func nib() -> UINib
}


extension NibLoadable {
    static func nib() -> UINib {
        return UINib(nibName: className, bundle: Bundle(for: self))
    }
}
