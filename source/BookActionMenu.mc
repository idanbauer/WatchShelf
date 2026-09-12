using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;
using Toybox.System;
using Toybox.Timer;
using Toybox.WatchUi;

// Per-book actions, reached from PlayMenu. Resume / Play from start hand the
// chosen book + mode to the native player via Media.startPlayback(args); the
// ContentIterator reads {item, mode} to position its cursor (see
// ContentIterator.applyStart). Delete queues this one book for removal, exactly
// like the old top-level book-row tap did.
class BookActionMenu extends WatchUi.Menu2 {

    function initialize(itemId, title) {
        Menu2.initialize({ :title => title });
        // A completed book has no meaningful resume cursor: offering it was
        // the UI half of the old "last part repeats" bug. Start-over remains
        // available and immediately clears finished once playback is reported.
        if (!Progress.isFinished(itemId)) {
            addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.resume), null, "resume", null));
        }
        // Tail-only downloads cannot literally start at 0. Name the action for
        // what the player can do: begin at the earliest downloaded part.
        var startLabel = (BookStore.first(itemId) > 0)
            ? Rez.Strings.playFromDownloadedStart : Rez.Strings.playFromStart;
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(startLabel), null, "start", null));
        addItem(new WatchUi.MenuItem(WatchUi.loadResource(Rez.Strings.deleteBook), null, "delete", null));
    }
}

class BookActionMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var mItemId;
    private var mLaunching;
    private var mCancelled;
    private var mResumeTimer;
    private var mDeferLiveProgress;

    function initialize(itemId) {
        Menu2InputDelegate.initialize();
        mItemId = itemId;
        mLaunching = false;
        mCancelled = false;
        mResumeTimer = null;
        mDeferLiveProgress = false;
    }

    function onSelect(item) {
        if (mLaunching) { return; }
        var id = item.getId();

        // Resume from the synced position; Play from start begins at 0. Both pass
        // the book id + mode to the native player, which launches playback mode
        // and hands the args to our ContentDelegate/ContentIterator.
        if ((id instanceof Toybox.Lang.String) && id.equals("resume")) {
            resumePlayback();
            return;
        }
        if ((id instanceof Toybox.Lang.String) && id.equals("start")) {
            mDeferLiveProgress = false;
            launchPlayback("start");
            return;
        }

        // Delete this one book (shared path: queue + sync, evicts the chunks).
        // A single book is far less destructive than "delete all", so no extra
        // confirm here. Pop back to the book list afterwards.
        if ((id instanceof Toybox.Lang.String) && id.equals("delete")) {
            Downloads.queueDelete([mItemId]);
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
            return;
        }
    }

    // Pull before playback starts so Resume can choose the furthest position.
    function resumePlayback() {
        mDeferLiveProgress = false;
        if (!AbsApi.isConfigured()) {
            launchPlayback("resume");
            return;
        }
        var settings = System.getDeviceSettings();
        if ((settings has :connectionAvailable) && !settings.connectionAvailable) {
            mDeferLiveProgress = true;
            launchPlayback("resume");
            return;
        }
        mLaunching = true;
        Notify.flash(Rez.Strings.syncing);
        mResumeTimer = new Timer.Timer();
        mResumeTimer.start(method(:onResumeTimeout), 2500, false);
        try {
            AbsApi.getProgress(mItemId, method(:onResumeProgress));
        } catch (e) {
            stopResumeTimer();
            mLaunching = false;
            mDeferLiveProgress = true;
            launchPlayback("resume");
        }
    }

    function onResumeProgress(code, data) {
        if (mCancelled || !mLaunching) { return; }
        stopResumeTimer();
        if (code == 200) {
            var pulled = AbsApi.readProgress(data);
            if (pulled != null) {
                Progress.mergeServer(mItemId, pulled[0], pulled[1], pulled[2]);
            }
        } else {
            mDeferLiveProgress = true;
        }
        mLaunching = false;
        launchPlayback("resume");
    }

    function onResumeTimeout() {
        mResumeTimer = null;
        if (mCancelled || !mLaunching) { return; }
        mLaunching = false;
        mDeferLiveProgress = true;
        launchPlayback("resume");
    }

    function stopResumeTimer() {
        if (mResumeTimer != null) {
            mResumeTimer.stop();
            mResumeTimer = null;
        }
    }

    function launchPlayback(mode) {
        // The native player can retain its current cached Content when this
        // provider is already active, even though startPlayback supplies a new
        // delegate payload. Stop that app-owned session first so selecting a
        // different book cannot resume the previous book's final/current part.
        // stopPlayback arrived after our minimum API, so keep older supported
        // devices on the legacy start-only path.
        if (Media has :stopPlayback) { Media.stopPlayback(); }
        Media.startPlayback({
            "item" => mItemId,
            "mode" => mode,
            "deferLiveProgress" => mDeferLiveProgress
        });
    }

    function onBack() {
        mCancelled = true;
        stopResumeTimer();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
