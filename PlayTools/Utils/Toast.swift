//
//  Toast.swift
//  PlayTools
//

import Foundation
import UIKit

class Toast {
    public static func showOver(msg: String) {
        if let parent = screen.keyWindow {
            Toast.show(message: msg, parent: parent)
        }
    }

    // swiftlint:disable function_body_length

    private static func show(message: String, parent: UIView) {
        let toastContainer = UIView(frame: CGRect())
        toastContainer.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toastContainer.alpha = 0.0
        toastContainer.layer.cornerRadius = 25
        toastContainer.clipsToBounds  =  true
        toastContainer.isUserInteractionEnabled = false

        let toastLabel = UILabel(frame: CGRect())
        toastLabel.textColor = UIColor.white
        toastLabel.textAlignment = .center
        toastLabel.font.withSize(12.0)
        toastLabel.text = message
        toastLabel.clipsToBounds  =  true
        toastLabel.numberOfLines = 0

        toastContainer.addSubview(toastLabel)
        parent.addSubview(toastContainer)

        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastContainer.translatesAutoresizingMaskIntoConstraints = false

        let toastConstraint1 = NSLayoutConstraint(item: toastLabel,
                                                  attribute: .leading,
                                                  relatedBy: .equal,
                                                  toItem: toastContainer,
                                                  attribute: .leading,
                                                  multiplier: 1,
                                                  constant: 15)
        let toastConstraint2 = NSLayoutConstraint(item: toastLabel,
                                                  attribute: .trailing,
                                                  relatedBy: .equal,
                                                  toItem: toastContainer,
                                                  attribute: .trailing,
                                                  multiplier: 1,
                                                  constant: -15)
        let toastConstraint3 = NSLayoutConstraint(item: toastLabel,
                                                  attribute: .bottom,
                                                  relatedBy: .equal,
                                                  toItem: toastContainer,
                                                  attribute: .bottom,
                                                  multiplier: 1,
                                                  constant: -15)
        let toastConstraint4 = NSLayoutConstraint(item: toastLabel,
                                                  attribute: .top,
                                                  relatedBy: .equal,
                                                  toItem: toastContainer,
                                                  attribute: .top,
                                                  multiplier: 1,
                                                  constant: 15)
        toastContainer.addConstraints([toastConstraint1, toastConstraint2, toastConstraint3, toastConstraint4])

        let controllerConstraint1 = NSLayoutConstraint(item: toastContainer,
                                                       attribute: .leading,
                                                       relatedBy: .equal,
                                                       toItem: parent,
                                                       attribute: .leading,
                                                       multiplier: 1,
                                                       constant: 65)
        let controllerConstraint2 = NSLayoutConstraint(item: toastContainer,
                                                       attribute: .trailing,
                                                       relatedBy: .equal,
                                                       toItem: parent,
                                                       attribute: .trailing,
                                                       multiplier: 1,
                                                       constant: -65)
        let controllerConstraint3 = NSLayoutConstraint(item: toastContainer,
                                                       attribute: .bottom,
                                                       relatedBy: .equal,
                                                       toItem: parent,
                                                       attribute: .bottom,
                                                       multiplier: 1,
                                                       constant: -75)
        parent.addConstraints([controllerConstraint1, controllerConstraint2, controllerConstraint3])

        UIView.animate(withDuration: 0.5, delay: 0.0, options: .curveEaseIn, animations: {
            toastContainer.alpha = 1.0
        }, completion: { _ in
            UIView.animate(withDuration: 0.5, delay: 1.5, options: .curveEaseOut, animations: {
                toastContainer.alpha = 0.0
            }, completion: {_ in
                toastContainer.removeFromSuperview()
            })
        })
    }
}
