#if os(macOS)
import AppKit
import SwiftUI

struct HorizontalAboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Horizontal") {
                HorizontalAboutPanel.show()
            }
        }
    }
}

private enum HorizontalAboutPanel {
    @MainActor
    static func show() {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.paragraphSpacing = 6

        let credits = NSMutableAttributedString(
            string: creditsText,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        )
        let creditsNSString = credits.string as NSString
        let emailRange = creditsNSString.range(of: "hello@twarge.com")
        if emailRange.location != NSNotFound {
            credits.addAttributes(
                [
                    .link: URL(string: "mailto:hello@twarge.com")!,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.linkColor
                ],
                range: emailRange
            )
        }

        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Horizontal",
            .credits: credits
        ])
    }

    private static let creditsText = """
Made by Twarge LLC
hello@twarge.com

Horizontal
Copyright 2026 Twarge LLC.
Licensed under the Apache License, Version 2.0.
Full text: Contents/Resources/LICENSE.txt

Third-party license notices

Open CASCADE Technology (OCCT)
Copyright OPEN CASCADE S.A.S.
Licensed under GNU LGPL 2.1 with the Open CASCADE exception.
Horizontal makes use of and is based on facilities provided by Open CASCADE Technology software.
Full texts: Contents/Resources/ThirdPartyLicenses/OpenCascade/LICENSE_LGPL_21.txt and Contents/Resources/ThirdPartyLicenses/OpenCascade/OCCT_LGPL_EXCEPTION.txt

RapidJSON
Copyright (C) 2015 THL A29 Limited, a Tencent company, and Milo Yip.
Licensed under the MIT License, with additional notices included in the full license file.
Full text: Contents/Resources/ThirdPartyLicenses/RapidJSON/license.txt

Clipper
Copyright Angus Johnson 2010-2017.
Licensed under the Boost Software License 1.0.
Full text: Contents/Resources/ThirdPartyLicenses/Clipper/License.txt

mapbox/earcut.hpp
Copyright (c) 2015, Mapbox.
Licensed under the ISC License.
Full text: Contents/Resources/ThirdPartyLicenses/earcut/LICENSE

Hershey stroke font tables (via OpenCV)
Copyright (C) 2000-2020, Intel Corporation. Copyright (C) 2009-2011, Willow Garage Inc.
Licensed under the BSD 3-Clause License.
The vector outlines originate with Dr. A. V. Hershey at the US National Bureau of Standards and are not subject to copyright.
Full text: Contents/Resources/ThirdPartyLicenses/Hershey/LICENSE (in-tree copy: Vendor/Hersheyish/LICENSE)
"""
}
#endif
