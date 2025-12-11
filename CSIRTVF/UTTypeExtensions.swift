//
//  UTTypeExtensions.swift
//  SecVF
//
//  Uniform Type Identifier extensions for file types used in SecVF.
//

import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// ISO disk image file type
    static let iso = UTType(filenameExtension: "iso")!

    /// macOS bundle file type
    static let bundle = UTType(filenameExtension: "bundle")!
}
