//
//  AudioUnitViewController.swift
//  FD808AU
//
//  Created by Dev 101 on 6/17/26.
//

import Combine
import CoreAudioKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.FB-808.FD808AU", category: "AudioUnitViewController")

@MainActor
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    var audioUnit: AUAudioUnit?
    
    var hostingController: HostingController<FD808AUMainView>?
    
    private var observation: NSKeyValueObservation?

    /// The audio unit the hosted view was built for, and the observable tree backing it. Both are
    /// kept so a repeated `configureSwiftUIView` call is a no-op and the previous tree's AUParameter
    /// observers can be revoked when the view is replaced.
    private var configuredAudioUnit: AUAudioUnit?
    private var observableTree: ObservableAUParameterGroup?

    /// What the editor asks the host for, and the smallest size the rows stay usable at (below it the
    /// content scrolls, so a short/compact host window can still reach the keyboard).
    static let preferredEditorSize = FD808AULayout.preferredContentSize
    static let minimumEditorSize = FD808AULayout.minimumContentSize

    /// Pure decision behind `configureSwiftUIView`: build the hosted view once per audio unit. The AU
    /// factory configures the view from its `defer` and `viewDidLoad` configures it again, so without
    /// this the tree (and every AUParameter observer it registers) is built twice per instantiation.
    static func shouldConfigure(existing: AUAudioUnit?, incoming: AUAudioUnit) -> Bool {
        guard let existing else { return true }
        return existing !== incoming
    }

	/* iOS View lifcycle
	public override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		// Recreate any view related resources here..
	}

	public override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)

		// Destroy any view related content here..
	}
	*/

	/* macOS View lifcycle
	public override func viewWillAppear() {
		super.viewWillAppear()
		
		// Recreate any view related resources here..
	}

	public override func viewDidDisappear() {
		super.viewDidDisappear()

		// Destroy any view related content here..
	}
	*/

	deinit {
        // AUParameter observers are registered with objects owned by the host; revoke them so the
        // observer closures (and the view state they capture) do not outlive the editor. `tearDown`
        // is main-actor isolated, so hand the tree over rather than calling it from `deinit`.
        if let tree = observableTree {
            Task { @MainActor in tree.tearDown() }
        }
	}

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = Self.preferredEditorSize

        // Accessing the `audioUnit` parameter prompts the AU to be created via createAudioUnit(with:)
        guard let audioUnit = self.audioUnit else {
            return
        }
        configureSwiftUIView(audioUnit: audioUnit)
    }
    
	nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
		return try DispatchQueue.main.sync {
			
			audioUnit = try FD808AUAudioUnit(componentDescription: componentDescription, options: [])
			
			guard let audioUnit = self.audioUnit as? FD808AUAudioUnit else {
				log.error("Unable to create FD808AUAudioUnit")
				return audioUnit!
			}
			
			defer {
				// Configure the SwiftUI view after creating the AU, instead of in viewDidLoad,
				// so that the parameter tree is set up before we build our @AUParameterUI properties
				DispatchQueue.main.async {
					self.configureSwiftUIView(audioUnit: audioUnit)
				}
			}
			
			audioUnit.setupParameterTree(FD808AUParameterSpecs.createAUParameterTree())
			
			self.observation = audioUnit.observe(\.allParameterValues, options: [.new]) { object, change in
				guard let tree = audioUnit.parameterTree else { return }
				
				// This insures the Audio Unit gets initial values from the host.
				for param in tree.allParameters { param.value = param.value }
			}
			
			guard audioUnit.parameterTree != nil else {
				log.error("Unable to access AU ParameterTree")
				return audioUnit
			}
			
			return audioUnit
		}
	}
    
    private func configureSwiftUIView(audioUnit: AUAudioUnit) {
        // Idempotent: `viewDidLoad` and `createAudioUnit`'s `defer` both call this for a normal
        // instantiation, and building the tree twice registers every AUParameter observer twice
        // (each extra closure is dispatched on every host-side parameter change).
        guard Self.shouldConfigure(existing: configuredAudioUnit, incoming: audioUnit) else { return }

        if let host = hostingController {
            host.removeFromParent()
            host.view.removeFromSuperview()
        }
        // Revoke the replaced tree's AUParameter observers instead of leaking them for the life of
        // the audio unit.
        observableTree?.tearDown()
        observableTree = nil
        hostingController = nil
        configuredAudioUnit = audioUnit
        
        guard let observableParameterTree = audioUnit.observableParameterTree else {
            return
        }
        observableTree = observableParameterTree
        let content = FD808AUMainView(parameterTree: observableParameterTree, audioUnit: audioUnit as? FD808AUAudioUnit)
        let host = HostingController(rootView: content)
        self.addChild(host)
        host.view.frame = self.view.bounds
        self.view.addSubview(host.view)
        hostingController = host
        
        // Make sure the SwiftUI view fills the full area provided by the view controller
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.topAnchor.constraint(equalTo: self.view.topAnchor).isActive = true
        host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor).isActive = true
        host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor).isActive = true
        host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor).isActive = true
        // Optional min-size floor: the host is free to give a smaller window (the content scrolls),
        // but it should not have to guess what the editor needs.
        let minWidth = host.view.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumEditorSize.width)
        let minHeight = host.view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumEditorSize.height)
        minWidth.priority = .defaultHigh
        minHeight.priority = .defaultHigh
        minWidth.isActive = true
        minHeight.isActive = true
        self.view.bringSubviewToFront(host.view)
    }
    
}
