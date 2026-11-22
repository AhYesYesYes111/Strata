package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestDeletingIgnoresHiddenActions(t *testing.T) {
	keys := []tea.KeyMsg{{Type: tea.KeyDown}, {Type: tea.KeyDelete}, {Type: tea.KeyEnter}, {Type: tea.KeyEsc}, keyRunes("r"), keyRunes(" "), keyRunes("o")}
	for _, key := range keys {
		t.Run(key.String(), func(t *testing.T) {
			m := newModel(t.TempDir(), false)
			m.scanning = false
			m.deleting = true
			m.entries = []dirEntry{{Name: "first", Path: filepath.Join(m.path, "first"), Size: 1, IsDir: true}, {Name: "second", Path: filepath.Join(m.path, "second"), Size: 2}}
			next, cmd := m.Update(key)
			got := next.(model)
			if cmd != nil || got.path != m.path || got.selected != m.selected || got.deleteConfirm || len(got.multiSelected) != 0 || got.scanning {
				t.Fatalf("busy input changed state: key=%s path=%s selected=%d confirm=%v scanning=%v cmd=%v", key.String(), got.path, got.selected, got.deleteConfirm, got.scanning, cmd != nil)
			}
		})
	}
}

func TestDeletingKeepsQuitKeys(t *testing.T) {
	for _, key := range []tea.KeyMsg{keyRunes("q"), keyRunes("Q"), {Type: tea.KeyCtrlC}} {
		m := model{deleting: true}
		_, cmd := m.Update(key)
		if cmd == nil {
			t.Fatalf("%s did not quit", key.String())
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Fatalf("%s did not return QuitMsg", key.String())
		}
	}
}

func TestLiveSortStartsFrozenWhateverTheEnvironment(t *testing.T) {
	t.Setenv("MOLE_ANALYZE_LIVE_SORT", "continuous")
	m := newModel(t.TempDir(), false)
	if m.liveSortMode != liveSortFreezeOnMove {
		t.Fatalf("live sort mode = %v, want freeze-on-move", m.liveSortMode)
	}
}

func TestLiveScanRejectsOlderSamePathStart(t *testing.T) {
	m := newModel(t.TempDir(), false)
	oldCmd := m.scanCmd(m.path)
	newCmd := m.scanCmd(m.path)
	newer := newCmd().(liveScanStartMsg)
	next, _ := m.Update(newer)
	m = next.(model)
	older := oldCmd().(liveScanStartMsg)
	next, _ = m.Update(older)
	got := next.(model)
	defer got.cancelLiveScan()
	if got.liveScanID != newer.id {
		t.Fatalf("older request replaced newest scan: got=%d newest=%d", got.liveScanID, newer.id)
	}
}

func TestLiveScanRejectsStartAfterCancel(t *testing.T) {
	m := newModel(t.TempDir(), false)
	cmd := m.scanCmd(m.path)
	m.cancelLiveScan()
	start := cmd().(liveScanStartMsg)
	if !errors.Is(start.err, context.Canceled) {
		t.Fatalf("canceled command still enumerated directory: %v", start.err)
	}
	next, wait := m.Update(start)
	got := next.(model)
	defer got.cancelLiveScan()
	if got.liveScanID != 0 || wait != nil {
		t.Fatalf("canceled queued request became active: id=%d", got.liveScanID)
	}
}

func TestLiveScanRejectsDelayedStartedRequest(t *testing.T) {
	m := newModel(t.TempDir(), false)
	oldStart := m.scanCmd(m.path)().(liveScanStartMsg)
	newerCmd := m.scanCmd(m.path)
	newStart := newerCmd().(liveScanStartMsg)
	next, _ := m.Update(newStart)
	m = next.(model)
	next, cmd := m.Update(oldStart)
	got := next.(model)
	defer got.cancelLiveScan()
	if got.liveScanID != newStart.id || cmd != nil {
		t.Fatal("delayed start superseded active request")
	}
}

func TestLiveScanCurrentRequestCompletes(t *testing.T) {
	m := newModel(t.TempDir(), false)
	cmd := m.scanCmd(m.path)
	next, wait := m.Update(cmd())
	m = next.(model)
	if wait == nil {
		t.Fatal("current request did not start event delivery")
	}
	next, _ = m.Update(wait())
	got := next.(model)
	if got.scanning || got.liveScanID != 0 {
		t.Fatalf("empty directory did not complete: scanning=%v id=%d", got.scanning, got.liveScanID)
	}
}

func TestMissingChildDoesNotExposeParentActions(t *testing.T) {
	m := newModel(t.TempDir(), false)
	child := filepath.Join(m.path, "vanished")
	m.scanning = false
	m.entries = []dirEntry{{Name: "vanished", Path: child, IsDir: true}}
	m.largeFiles = []fileEntry{{Name: "parent-file", Path: filepath.Join(m.path, "parent-file"), Size: 10}}
	m.totalSize = 10
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	m = next.(model)
	if cmd == nil || m.path != child || len(m.entries)+len(m.largeFiles) != 0 {
		t.Fatalf("entering missing child exposed parent listing at %q", m.path)
	}
	for _, scan := range cmd().(tea.BatchMsg) {
		if msg, ok := scan().(liveScanStartMsg); ok {
			if msg.err == nil {
				t.Fatal("missing directory unexpectedly enumerated")
			}
			next, _ = m.Update(msg)
			m = next.(model)
			break
		}
	}
	if m.scanning || m.scanState != scanUnavailable || m.totalSize != 0 {
		t.Fatal("failed scan retained parent measurements")
	}
	for _, large := range []bool{false, true} {
		m.showLargeFiles = large
		next, cmd = m.Update(tea.KeyMsg{Type: tea.KeyDelete})
		m = next.(model)
		if cmd != nil || m.deleteConfirm || m.deleteTarget != nil {
			t.Fatal("failed scan exposed a parent deletion target")
		}
	}
	next, _ = m.goBack()
	parent := next.(model)
	if len(parent.entries) != 1 || parent.entries[0].Path != child || len(parent.largeFiles) != 1 || parent.totalSize != 10 {
		t.Fatal("going back failed to restore parent listing")
	}
}

func TestFailedRefreshDropsCachedActions(t *testing.T) {
	m := newModel(t.TempDir(), false)
	child := filepath.Join(m.path, "missing")
	m.entries = []dirEntry{{Name: "missing", Path: child, IsDir: true}}
	row := dirEntry{Name: "stale", Path: filepath.Join(child, "stale"), Size: 10}
	m.cache[child] = historyEntry{Entries: []dirEntry{row}, TotalSize: 10, NeedsRefresh: true}
	next, _ := m.enterSelectedDir()
	m = next.(model)
	if !m.scanning || len(m.entries) != 1 || m.entries[0] != row {
		t.Fatal("expected the child's own cached listing during refresh")
	}
	m.multiSelected = map[string]bool{row.Path: true}
	next, _ = m.Update(liveScanStartMsg{id: m.liveScanID, path: child, err: errors.New("scan failed")})
	m = next.(model)
	next, cmd := m.Update(tea.KeyMsg{Type: tea.KeyDelete})
	m = next.(model)
	if _, cached := m.cache[child]; cached || m.scanning || m.deleteConfirm || cmd != nil || len(m.multiSelected)+len(m.entries) != 0 {
		t.Fatal("failed refresh left a cached deletion target")
	}
}

func TestGoingBackDropsChildSelection(t *testing.T) {
	parent := t.TempDir()
	child := filepath.Join(parent, "folder")
	childItem := filepath.Join(child, "file")
	m := newModel(child, false)
	m.scanning = false
	m.history = []historyEntry{{Path: parent, Entries: []dirEntry{{Path: child, IsDir: true}}}}
	m.multiSelected = map[string]bool{childItem: true}
	m.largeMultiSelected = map[string]bool{childItem: true}
	next, _ := m.goBack()
	m = next.(model)
	if m.path != parent || len(m.multiSelected)+len(m.largeMultiSelected) != 0 {
		t.Fatal("returning to parent retained actions on child entries")
	}
}
