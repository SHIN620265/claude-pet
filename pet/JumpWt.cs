// WT tab-level jump helper (compiled into the resident via Add-Type). Pure ASCII.
// Windows Terminal keeps each tab's UI Automation Name equal to that tab's console
// title, so a session whose recorded fingerprint (its console title) matches a tab Name
// can be selected precisely. Both entry points return int (1 = the tab was selected,
// 0 = not found / could not select) and never throw: a 0 just leaves the window-level
// jump that already succeeded, so tab precision is a bonus and never a regression.
using System;
using System.Diagnostics;
using System.Windows.Automation;

public static class PetWtJump {
    // last UIA scan duration (ms) -- sampled by the resident for the V2 perf check
    public static long LastScanMs = 0;

    // Find the single TabItem under `host` whose Name equals `name`. Off-screen tabs can
    // be virtualized (Name comes back empty) -- realize them and re-read. Returns null on
    // zero OR multiple matches: an ambiguous match must never select the wrong tab.
    static AutomationElement FindTab(IntPtr host, string name) {
        Stopwatch sw = Stopwatch.StartNew();
        AutomationElement match = null;
        int hits = 0;
        try {
            AutomationElement root = AutomationElement.FromHandle(host);
            if (root != null) {
                Condition cond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem);
                AutomationElementCollection tabs = root.FindAll(TreeScope.Descendants, cond);
                for (int i = 0; i < tabs.Count; i++) {
                    AutomationElement t = tabs[i];
                    string tn = SafeName(t);
                    if (String.IsNullOrEmpty(tn)) {
                        object vp;
                        if (t.TryGetCurrentPattern(VirtualizedItemPattern.Pattern, out vp)) {
                            try { ((VirtualizedItemPattern)vp).Realize(); } catch {}
                            tn = SafeName(t);
                        }
                    }
                    if (tn == name) { hits++; match = t; }
                }
            }
        } catch { match = null; hits = 0; }
        sw.Stop(); LastScanMs = sw.ElapsedMilliseconds;
        return (hits == 1) ? match : null;
    }

    static string SafeName(AutomationElement e) {
        try { return e.Current.Name; } catch { return null; }
    }

    static bool SelectTab(AutomationElement t) {
        try {
            object sp;
            if (t.TryGetCurrentPattern(SelectionItemPattern.Pattern, out sp)) {
                ((SelectionItemPattern)sp).Select();
                return true;
            }
        } catch {}
        return false;
    }

    // direct match: the session is in a stable state, so its stored fingerprint still
    // equals the live tab Name
    public static int TryFocusTab(IntPtr host, string title) {
        if (String.IsNullOrEmpty(title)) return 0;
        AutomationElement t = FindTab(host, title);
        return (t != null && SelectTab(t)) ? 1 : 0;
    }

    // nonce match: a helper stamped a unique title on this session's tab; unique by
    // construction, so at most one tab can carry it
    public static int TryFocusNonce(IntPtr host, string nonce) {
        if (String.IsNullOrEmpty(nonce)) return 0;
        AutomationElement t = FindTab(host, nonce);
        return (t != null && SelectTab(t)) ? 1 : 0;
    }
}
