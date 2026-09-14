using Toybox.Application;
using Toybox.System;

// The two-way progress exchange, run as one bounded, SEQUENTIAL chain inside a
// sync (SyncDelegate.onStartSync). Order matters:
//
//   1. PULL every downloaded book's position from ABS and keep whichever side
//      is furthest along.
//   2. PUSH any farther watch position left dirty by that merge.
//
// One request at a time - same discipline as the download engine - so it never
// stacks requests into the 512KB sync heap. It runs as the FINAL step of a sync
// (SyncDelegate.finishSync), AFTER downloads/deletes are done, and invokes its
// continuation exactly once when the chain ends - even on a request error - so
// the sync always reaches notifySyncComplete. Nothing here is load-bearing for
// the download path: by the time it runs, downloads have already finished.
class ProgressSync {

    private var mPulls;    // [ itemId, ... ] downloaded books to pull
    private var mPushes;   // [ itemId, ... ] still-dirty books to push (built
                           // AFTER the pulls, so the merge has already run)
    private var mPhase;    // 0 = pulling, 1 = pushing
    private var mIdx;
    private var mCurId;
    private var mCurTs;
    private var mCurPos;
    private var mCurFinished;
    private var mCb;
    private var mPulled;
    private var mError;

    function initialize() {
        mPulls = [];
        mPushes = [];
        mPhase = 0;
        mIdx = 0;
        mPulled = {};
        mError = null;
    }

    function start(cb) {
        mCb = cb;
        try {
            var index = Application.Storage.getValue(Store.BOOK_INDEX);
            if (index == null) { index = []; }
            mPulls = index;
        } catch (e) {
            System.println("ProgressSync build failed: " + e.getErrorMessage());
            mPulls = [];
        }
        step();
    }

    function step() {
        try {
            if (mPhase == 0) {
                if (mIdx >= mPulls.size()) {
                    // Pulls done: NOW compute what remains dirty and push it.
                    var dirty = Progress.dirtyIds();
                    for (var i = 0; i < dirty.size(); ++i) {
                        if (mPulled[dirty[i]] == true) { mPushes.add(dirty[i]); }
                    }
                    mPhase = 1;
                    mIdx = 0;
                    step();
                    return;
                }
                mCurId = mPulls[mIdx];
                mIdx += 1;
                AbsApi.getProgress(mCurId, method(:onPullDone));
                return;
            }

            // Push phase.
            if (mIdx >= mPushes.size()) { finish(); return; }
            mCurId = mPushes[mIdx];
            mIdx += 1;
            var e = Progress.get(mCurId);
            if (e == null) { step(); return; }
            mCurTs = e[1];
            mCurPos = e[0];
            mCurFinished = Progress.entryFinished(e);
            // Always carry duration when known so a first offline write has
            // complete progress metadata. Ordinary positions omit isFinished;
            // moving below ABS's completion threshold reopens a reread.
            var duration = bookDuration(mCurId);
            var finishValue = mCurFinished ? true : null;
            AbsApi.postProgress(mCurId, e[0], duration, e[1],
                finishValue, method(:onPushDone));
        } catch (ex) {
            System.println("ProgressSync step failed: " + ex.getErrorMessage());
            if (mError == null) { mError = "Progress sync failed"; }
            // Never let a progress hiccup strand the sync - advance regardless.
            if (mPhase == 0 && mIdx >= mPulls.size()) {
                mPushes = [];
                mPhase = 1;
                mIdx = 0;
            }
            step();
        }
    }

    function onPullDone(code, data) {
        try {
            if (code == 200) {
                mPulled[mCurId] = true;
                var pr = AbsApi.readProgress(data); // [posSec, tsSec, finished] or null
                if (pr != null) {
                    var finished = (pr.size() > 2) ? pr[2] : null;
                    Progress.mergeServer(mCurId, pr[0], pr[1], finished);
                }
            } else if (mError == null) {
                mError = Errors.progressMessage(code);
            }
        } catch (ex) {
            System.println("ProgressSync pull failed: " + ex.getErrorMessage());
            if (mError == null) { mError = "Progress sync failed"; }
        }
        step();
    }

    function bookDuration(itemId) {
        var meta = BookStore.get(itemId);
        if ((meta == null) || (meta["durs"] == null)) { return null; }
        var total = 0;
        var durs = meta["durs"];
        for (var i = 0; i < durs.size(); ++i) { total += durs[i]; }
        return (total > 0) ? total : null;
    }

    function onPushDone(code, data) {
        if (code == 200) {
            Progress.markClean(mCurId, mCurTs, mCurPos, mCurFinished);
        }
        else { System.println("ProgressSync push failed: " + code); }
        if ((code != 200) && (mError == null)) {
            mError = Errors.progressMessage(code);
        }
        step();
    }

    function finish() {
        if (mCb != null) {
            var cb = mCb;
            mCb = null;
            cb.invoke(mError);
        }
    }
}
