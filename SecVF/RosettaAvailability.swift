//
//  RosettaAvailability.swift
//  SecVF
//
//  Created by Daxx on 11/6/25.
//  Copyright © 2025 Apple. All rights reserved.
//

import Foundation
import Virtualization

// Simple property to check Rosetta availability
let rosettaAvailability = VZLinuxRosettaDirectoryShare.availability

// Helper function to check if Rosetta is available
func isRosettaAvailable() -> Bool {
    return rosettaAvailability == .installed
}

// Helper function to check Rosetta status
func checkRosettaStatus() -> String {
    switch rosettaAvailability {
    case .notSupported:
        return "Rosetta is not supported on this system"
    case .notInstalled:
        return "Rosetta is not installed"
    case .installed:
        return "Rosetta is installed and available"
    @unknown default:
        return "Unknown Rosetta status"
    }
}
