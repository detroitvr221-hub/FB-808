//
//  FD808AU-Bridging-Header.h
//  FD808AU
//
//  Created by Dev 101 on 6/17/26.
//

#import "FD808AUParameterAddresses.h"
// The Xcode-template C++ kernel (FD808AUAUProcessHelper.hpp / FD808AUDSPKernel.hpp) is unused — the
// Swift AU renders through FD808Engine's SynthCore. Not imported here so the C++ std::span/CoreMIDI
// headers don't bleed into the Swift target.
