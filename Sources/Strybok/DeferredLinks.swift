import Foundation

/// Answer of ``Strybok/redeemPastedLink(_:)``.
public enum PastedLinkResult: Sendable, Hashable {
    /// The pasted link was exchanged and handed to ``Strybok/links()`` and the listeners,
    /// with ``ResolvedLink/isDeferred`` set.
    case delivered
    /// The string is not a link of this app with a valid code. Nothing was sent anywhere
    /// and the string was dropped. People have all kinds of things on their clipboard, so
    /// this is not an error to show.
    case notOurs
    /// The service refused the code: unknown, older than 24 hours, already used, or made
    /// for another app. Final for this installation.
    case notFound
    /// A deferred link was already delivered or refused in this installation; nothing
    /// was sent.
    case alreadyHandled
    /// `deferredLinks` is off; nothing was sent.
    case disabled
    /// The service could not be reached or was busy (the person can tap Paste again), or
    /// its answer was unusable, or the SDK was stopped.
    case failed
}

/// Where the deferred-link check stands, for developers and QA. Nothing about deferred
/// links is ever reported to `onError`: most people who install an app never tapped a
/// link, so finding nothing is the normal case.
///
/// Read it with ``Strybok/deferredLinkStatus`` or observe it with
/// ``Strybok/deferredLinkStatuses()``.
public enum DeferredLinkStatus: Sendable, Hashable {
    /// `deferredLinks` is off.
    case disabled
    /// The probabilistic-matching check of this launch has not finished yet: it begins
    /// once ``Strybok/start()`` has completed, or is running.
    case checking
    /// This launch could not finish the matching check (the service was not reachable
    /// or was busy). A later launch tries again, three launches at most.
    case pending
    /// The SDK is waiting for the app to call ``Strybok/redeemPastedLink(_:)`` or
    /// ``Strybok/skipPastedLink()``: either probabilistic matching is allowed and the
    /// clipboard probably holds a web address, or only the pasted-link flow is on and
    /// nothing has been pasted yet.
    case awaitingPaste
    /// A deferred link was delivered or refused in an earlier launch.
    case notFirstLaunch
    /// Matching is impossible here: not an iPhone, iPad or iPod touch, or no usable
    /// bundle identifier or preferred language.
    case unavailable
    /// Part of the shared status list (an Android install referrer without a code of
    /// ours). The iOS SDK never reports it.
    case noReferrer
    /// The service has no link: the pasted code was refused, or nothing matched (or more
    /// than one tap did).
    case notFound
    /// A normal link of this app arrived first, so the guessed one was dropped.
    case superseded
    /// A deferred link was handed to ``Strybok/links()`` and the listeners.
    case delivered
    /// Three launches could not finish the check, or the service's answer was unusable.
    case failed
}
