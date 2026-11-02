//
//  INSInteractionAnimator.swift
//  INSPhotoViewer
//
//  Created by Michal Zaborowski on 28.02.2016.
//  Copyright © 2016 Inspace Labs Sp z o. o. Spółka Komandytowa. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this library except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

import UIKit

/// Geometry and decisions of swipe-down-to-dismiss, modeled on the system Photos app.
/// Pure functions so the host app can unit test them.
public enum INSPhotosSwipeToDismiss {
    /// The photo shrinks down to this scale as it is dragged down by half the view height.
    public static let minimumScale: CGFloat = 0.7
    /// Background alpha at half the view height (the presenting screen shows through).
    public static let minimumBackgroundAlpha: CGFloat = 0.1
    /// Released below this fraction of the view height (and not flicked back up) dismisses.
    public static let dismissDistanceRatio: CGFloat = 0.12
    /// A downward flick at least this fast (pt/s) dismisses regardless of distance.
    public static let dismissVelocity: CGFloat = 800
    /// An upward flick faster than this (pt/s) cancels even past the distance threshold.
    public static let cancelUpwardVelocity: CGFloat = 200

    /// Downward, mostly vertical drags only. Horizontal drags page, upward drags do nothing.
    public static func shouldBegin(velocity: CGPoint) -> Bool {
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    public static func isZoomedIn(zoomScale: CGFloat, minimumZoomScale: CGFloat) -> Bool {
        return zoomScale > minimumZoomScale + 0.01
    }

    /// 0 at rest, 1 at half the view height. Dragging above the start counts as 0.
    public static func progress(verticalDelta: CGFloat, viewHeight: CGFloat) -> CGFloat {
        guard viewHeight > 0 else {
            return 0
        }
        return min(max(verticalDelta, 0) / (viewHeight / 2), 1)
    }

    public static func scale(verticalDelta: CGFloat, viewHeight: CGFloat) -> CGFloat {
        return 1 - (1 - minimumScale) * progress(verticalDelta: verticalDelta, viewHeight: viewHeight)
    }

    public static func backgroundAlpha(verticalDelta: CGFloat, viewHeight: CGFloat) -> CGFloat {
        return 1 - (1 - minimumBackgroundAlpha) * progress(verticalDelta: verticalDelta, viewHeight: viewHeight)
    }

    public static func shouldDismiss(verticalDelta: CGFloat, velocityY: CGFloat, viewHeight: CGFloat) -> Bool {
        if velocityY >= dismissVelocity {
            return true
        }
        return verticalDelta >= viewHeight * dismissDistanceRatio && velocityY > -cancelUpwardVelocity
    }
}

public class INSPhotosInteractionAnimator: NSObject, UIViewControllerInteractiveTransitioning {
    var animator: UIViewControllerAnimatedTransitioning?
    var viewToHideWhenBeginningTransition: UIView?
    var shouldAnimateUsingAnimator: Bool = false

    private var transitionContext: UIViewControllerContextTransitioning?

    public func startInteractiveTransition(_ transitionContext: UIViewControllerContextTransitioning) {
        viewToHideWhenBeginningTransition?.alpha = 0.0
        self.transitionContext = transitionContext
    }

    func handlePanWithPanGestureRecognizer(_ gestureRecognizer: UIPanGestureRecognizer, viewToPan: UIView, anchorPoint: CGPoint) {
        guard let fromView = transitionContext?.view(forKey: UITransitionContextViewKey.from) else {
            return
        }
        let translatedPanGesturePoint = gestureRecognizer.translation(in: fromView)
        let newCenterPoint = CGPoint(x: anchorPoint.x + translatedPanGesturePoint.x, y: anchorPoint.y + translatedPanGesturePoint.y)
        let verticalDelta = newCenterPoint.y - anchorPoint.y
        let viewHeight = fromView.bounds.height

        viewToPan.center = newCenterPoint
        let scale = INSPhotosSwipeToDismiss.scale(verticalDelta: verticalDelta, viewHeight: viewHeight)
        viewToPan.transform = CGAffineTransform(scaleX: scale, y: scale)
        fromView.backgroundColor = fromView.backgroundColor?.withAlphaComponent(INSPhotosSwipeToDismiss.backgroundAlpha(verticalDelta: verticalDelta, viewHeight: viewHeight))

        switch gestureRecognizer.state {
        case .ended:
            finishPanWithPanGestureRecognizer(gestureRecognizer, verticalDelta: verticalDelta, viewToPan: viewToPan, anchorPoint: anchorPoint)
        case .cancelled, .failed:
            finishPan(isDismissing: false, velocityY: 0, viewToPan: viewToPan, anchorPoint: anchorPoint)
        default:
            break
        }
    }

    func finishPanWithPanGestureRecognizer(_ gestureRecognizer: UIPanGestureRecognizer, verticalDelta: CGFloat, viewToPan: UIView, anchorPoint: CGPoint) {
        guard let fromView = transitionContext?.view(forKey: UITransitionContextViewKey.from) else {
            return
        }
        let velocityY = gestureRecognizer.velocity(in: fromView).y
        let isDismissing = INSPhotosSwipeToDismiss.shouldDismiss(verticalDelta: verticalDelta, velocityY: velocityY, viewHeight: fromView.bounds.height)
        finishPan(isDismissing: isDismissing, velocityY: velocityY, viewToPan: viewToPan, anchorPoint: anchorPoint)
    }

    private func finishPan(isDismissing: Bool, velocityY: CGFloat, viewToPan: UIView, anchorPoint: CGPoint) {
        guard let fromView = transitionContext?.view(forKey: UITransitionContextViewKey.from) else {
            return
        }
        let panDismissMaximumDuration = 0.45

        if isDismissing, let animator = self.animator, let transitionContext = transitionContext, shouldAnimateUsingAnimator {
            // Zoom into the current photo's cell. Start from a snapshot at the photo's current
            // (shrunken) size so the zoom does not jump back to full size first.
            if let transitionAnimator = animator as? INSPhotosTransitionAnimator, let startingView = transitionAnimator.startingView {
                let snapshot = startingView.ins_snapshotView()
                let scale = viewToPan.transform.a
                snapshot.transform = snapshot.transform.scaledBy(x: scale, y: scale)
                transitionAnimator.startingViewForAnimation = snapshot
            }
            animator.animateTransition(using: transitionContext)
            self.transitionContext = nil
            return
        }

        if isDismissing {
            // No cell to return to (scrolled away or hidden): slide out downward while fading.
            let finalCenter = CGPoint(x: viewToPan.center.x, y: fromView.bounds.midY + fromView.bounds.height)
            var duration = Double(abs(finalCenter.y - viewToPan.center.y) / max(abs(velocityY), 1))
            duration = min(duration, panDismissMaximumDuration)
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
                viewToPan.center = finalCenter
                fromView.backgroundColor = fromView.backgroundColor?.withAlphaComponent(0)
            }, completion: { _ in
                self.completePan(isDismissing: true)
            })
        } else {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                viewToPan.center = anchorPoint
                viewToPan.transform = .identity
                fromView.backgroundColor = fromView.backgroundColor?.withAlphaComponent(1)
            }, completion: { _ in
                self.completePan(isDismissing: false)
            })
        }
    }

    private func completePan(isDismissing: Bool) {
        if isDismissing {
            transitionContext?.finishInteractiveTransition()
        } else {
            transitionContext?.cancelInteractiveTransition()
            // A later non-interactive dismissal must not reuse this drag's snapshots (they may show another photo's cell).
            if let transitionAnimator = animator as? INSPhotosTransitionAnimator {
                transitionAnimator.startingViewForAnimation = nil
                transitionAnimator.endingViewForAnimation = nil
            }
        }
        viewToHideWhenBeginningTransition?.alpha = 1.0
        transitionContext?.completeTransition(isDismissing && !(transitionContext?.transitionWasCancelled ?? false))
        transitionContext = nil
    }
}
