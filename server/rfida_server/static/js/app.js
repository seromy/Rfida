/* Rfida back office — progressive enhancement only.
   Every page works without this file (forms post, links navigate); the script adds
   the side-nav toggle, tabs, confirm dialogs, row selection and the loan picker. */
(function () {
  "use strict";

  var body = document.body;
  var $ = function (sel, root) { return (root || document).querySelector(sel); };
  var $$ = function (sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); };

  function store(key, value) {
    try {
      if (value === undefined) return window.localStorage.getItem(key);
      window.localStorage.setItem(key, value);
    } catch (e) { /* storage blocked: the UI just won't remember */ }
    return null;
  }

  /* ---------------------------------------------------------- side navigation */
  var navToggle = $("#nav-toggle");
  var backdrop = $(".sidenav-backdrop");
  var mobile = window.matchMedia("(max-width: 56.25rem)");

  function syncNav() {
    var expanded = mobile.matches ? body.classList.contains("nav-open") : !body.classList.contains("nav-collapsed");
    if (navToggle) navToggle.setAttribute("aria-expanded", String(expanded));
    if (backdrop) backdrop.hidden = !(mobile.matches && body.classList.contains("nav-open"));
  }
  if (store("rfida.nav") === "collapsed" && !mobile.matches) body.classList.add("nav-collapsed");
  if (navToggle) {
    navToggle.addEventListener("click", function () {
      if (mobile.matches) {
        body.classList.toggle("nav-open");
      } else {
        body.classList.toggle("nav-collapsed");
        store("rfida.nav", body.classList.contains("nav-collapsed") ? "collapsed" : "expanded");
      }
      syncNav();
    });
  }
  if (backdrop) backdrop.addEventListener("click", function () { body.classList.remove("nav-open"); syncNav(); });
  if (mobile.addEventListener) mobile.addEventListener("change", function () { body.classList.remove("nav-open"); syncNav(); });
  syncNav();

  /* ---------------------------------------------------------- global search shortcut */
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && body.classList.contains("nav-open")) {
      body.classList.remove("nav-open");
      syncNav();
      return;
    }
    if (e.key !== "/" || e.ctrlKey || e.metaKey || e.altKey) return;
    var t = e.target;
    if (t && (/^(input|textarea|select)$/i.test(t.tagName) || t.isContentEditable)) return;
    if ($("dialog[open]")) return;
    var box = $(".shell-search input");
    if (box) { e.preventDefault(); box.focus(); box.select(); }
  });

  /* ---------------------------------------------------------- message strips */
  $$(".strip-close").forEach(function (btn) {
    btn.addEventListener("click", function () { btn.closest(".strip").remove(); });
  });
  $$('.strip[data-autodismiss="yes"]').forEach(function (strip) {
    window.setTimeout(function () { if (strip.isConnected) strip.remove(); }, 7000);
  });

  /* ---------------------------------------------------------- tabs (object pages) */
  $$("[data-tabs]").forEach(function (bar) {
    var tabs = $$('[role="tab"]', bar);
    if (!tabs.length) return;

    function select(tab, focus, updateHash) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
        var panel = document.getElementById(t.getAttribute("aria-controls"));
        if (panel) panel.hidden = !on;
      });
      if (focus) tab.focus();
      if (updateHash && window.history.replaceState) {
        window.history.replaceState(null, "", "#" + tab.getAttribute("aria-controls").replace(/^panel-/, ""));
      }
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener("click", function () { select(tab, false, true); });
      tab.addEventListener("keydown", function (e) {
        var next = null;
        if (e.key === "ArrowRight") next = tabs[(i + 1) % tabs.length];
        else if (e.key === "ArrowLeft") next = tabs[(i - 1 + tabs.length) % tabs.length];
        else if (e.key === "Home") next = tabs[0];
        else if (e.key === "End") next = tabs[tabs.length - 1];
        if (next) { e.preventDefault(); select(next, true, true); }
      });
    });

    var wanted = window.location.hash.replace("#", "");
    var initial = tabs.filter(function (t) { return t.getAttribute("aria-controls") === "panel-" + wanted; })[0]
      || tabs.filter(function (t) { return t.getAttribute("aria-selected") === "true"; })[0]
      || tabs[0];
    select(initial, false, false);

    // Links elsewhere on the page can jump to a tab: <a href="#loans" data-tab-link>.
    $$("[data-tab-link]").forEach(function (a) {
      a.addEventListener("click", function (e) {
        var target = tabs.filter(function (t) { return t.getAttribute("aria-controls") === "panel-" + a.getAttribute("href").slice(1); })[0];
        if (target) { e.preventDefault(); select(target, true, true); }
      });
    });
  });

  /* ---------------------------------------------------------- confirm dialog */
  var confirmDialog = $("#confirm-dialog");
  var pendingForm = null;

  if (confirmDialog && typeof confirmDialog.showModal === "function") {
    var msg = $("#confirm-message", confirmDialog);
    var okBtn = $("#confirm-ok", confirmDialog);
    confirmDialog.addEventListener("close", function () {
      var form = pendingForm;
      pendingForm = null;
      if (form && confirmDialog.returnValue === "ok") {
        form.dataset.confirmed = "1";
        if (form.requestSubmit) form.requestSubmit(); else form.submit();
      }
      confirmDialog.returnValue = "";
    });
    document.addEventListener("submit", function (e) {
      var form = e.target;
      if (!form.matches || !form.hasAttribute("data-confirm") || form.dataset.confirmed === "1") return;
      e.preventDefault();
      e.stopImmediatePropagation();
      pendingForm = form;
      msg.textContent = form.getAttribute("data-confirm");
      okBtn.textContent = form.getAttribute("data-confirm-label") || "確定";
      confirmDialog.showModal();
      $("#confirm-cancel", confirmDialog).focus();
    }, true);
  } else {
    document.addEventListener("submit", function (e) {
      var form = e.target;
      if (form.matches && form.hasAttribute("data-confirm") && !window.confirm(form.getAttribute("data-confirm"))) e.preventDefault();
    }, true);
  }

  /* ---------------------------------------------------------- generic dialogs */
  $$("[data-open-dialog]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var dlg = document.getElementById(btn.getAttribute("data-open-dialog"));
      if (dlg && dlg.showModal) {
        dlg.showModal();
        var first = $("input:not([type=hidden]), textarea, select", dlg);
        if (first) first.focus();
      }
    });
  });
  $$("[data-close-dialog]").forEach(function (btn) {
    btn.addEventListener("click", function () { var d = btn.closest("dialog"); if (d) d.close(); });
  });

  /* ---------------------------------------------------------- double-submit guard */
  document.addEventListener("submit", function (e) {
    var form = e.target;
    if (e.defaultPrevented || !form.matches || (form.method || "").toLowerCase() !== "post") return;
    if (form.dataset.submitting === "1") { e.preventDefault(); return; }
    form.dataset.submitting = "1";
    var btn = e.submitter || $('button[type="submit"]', form);
    if (btn) window.setTimeout(function () { btn.setAttribute("aria-busy", "true"); }, 0);
  });
  window.addEventListener("pageshow", function () {
    $$("form[data-submitting]").forEach(function (f) { delete f.dataset.submitting; });
    $$('[aria-busy="true"]').forEach(function (b) { b.removeAttribute("aria-busy"); });
  });

  /* ---------------------------------------------------------- print button (CSP forbids inline handlers) */
  $$("[data-print]").forEach(function (btn) {
    btn.addEventListener("click", function () { window.print(); });
  });

  /* ---------------------------------------------------------- clickable rows */
  $$("tr[data-href]").forEach(function (row) {
    row.style.cursor = "pointer";
    row.addEventListener("click", function (e) {
      if (e.target.closest("a, button, input, select, textarea, label, summary")) return;
      var sel = window.getSelection && window.getSelection();
      if (sel && String(sel).length) return; // user is selecting text
      window.location.href = row.getAttribute("data-href");
    });
  });

  /* ---------------------------------------------------------- row selection */
  function groupBoxes(group) {
    return $$('input[type="checkbox"][data-select="' + group + '"]').filter(function (c) { return !c.disabled; });
  }
  function refreshGroup(group) {
    var boxes = groupBoxes(group);
    var checked = boxes.filter(function (c) { return c.checked; });
    boxes.forEach(function (c) {
      var row = c.closest("tr");
      if (row) {
        row.classList.toggle("is-selected", c.checked);
        $$("[data-enable-when-selected]", row).forEach(function (el) { el.disabled = !c.checked; });
      }
    });
    $$('[data-select-all="' + group + '"]').forEach(function (all) {
      all.checked = boxes.length > 0 && checked.length === boxes.length;
      all.indeterminate = checked.length > 0 && checked.length < boxes.length;
    });
    $$('[data-select-count="' + group + '"]').forEach(function (el) { el.textContent = String(checked.length); });
    $$('[data-needs-selection="' + group + '"]').forEach(function (el) {
      el.disabled = checked.length === 0;
      if (el.tagName === "A") el.setAttribute("aria-disabled", String(checked.length === 0));
    });
  }
  var groups = {};
  $$("[data-select]").forEach(function (c) { groups[c.getAttribute("data-select")] = true; });
  $$("[data-select-all]").forEach(function (a) { groups[a.getAttribute("data-select-all")] = true; });
  Object.keys(groups).forEach(function (group) {
    $$('input[data-select="' + group + '"]').forEach(function (c) {
      c.addEventListener("change", function () { refreshGroup(group); });
    });
    $$('[data-select-all="' + group + '"]').forEach(function (all) {
      all.addEventListener("change", function () {
        // only rows currently visible (not filtered out) are affected
        groupBoxes(group).forEach(function (c) {
          var row = c.closest("tr");
          if (!row || !row.hidden) c.checked = all.checked;
        });
        refreshGroup(group);
      });
    });
    refreshGroup(group);
  });

  /* ---------------------------------------------------------- loan picker: filter + paste EPCs */
  var picker = $("[data-picker]");
  if (picker) {
    var rows = $$("tbody tr[data-epc]", picker);
    var search = $("[data-filter-input]", picker);
    var category = $("[data-filter-category]", picker);
    var onlyAvail = $("[data-filter-available]", picker);
    var emptyRow = $("[data-filter-empty]", picker);

    function applyFilter() {
      var q = (search && search.value || "").trim().toLowerCase();
      var cat = category ? category.value : "";
      var avail = onlyAvail && onlyAvail.checked;
      var shown = 0;
      rows.forEach(function (row) {
        var ok = (!q || row.getAttribute("data-search").indexOf(q) !== -1)
          && (!cat || row.getAttribute("data-category") === cat)
          && (!avail || row.getAttribute("data-available") === "1");
        row.hidden = !ok;
        if (ok) shown++;
      });
      if (emptyRow) emptyRow.hidden = shown !== 0;
    }
    [search, category, onlyAvail].forEach(function (el) {
      if (el) { el.addEventListener("input", applyFilter); el.addEventListener("change", applyFilter); }
    });
    if (search) search.addEventListener("keydown", function (e) { if (e.key === "Enter") e.preventDefault(); });
    applyFilter();

    var pasteBtn = $("[data-paste-apply]", picker.closest("form") || document);
    var pasteBox = $("#f-epc_paste");
    var pasteOut = $("[data-paste-result]");
    if (pasteBtn && pasteBox) {
      pasteBtn.addEventListener("click", function () {
        var tokens = pasteBox.value.split(/[\s,;]+/).filter(Boolean).map(function (t) { return t.toUpperCase(); });
        var byEpc = {};
        rows.forEach(function (r) { byEpc[r.getAttribute("data-epc")] = r; });
        var matched = 0, blocked = [], unknown = [];
        tokens.forEach(function (epc) {
          var row = byEpc[epc];
          if (!row) { unknown.push(epc); return; }
          var box = $('input[type="checkbox"]', row);
          if (!box || box.disabled) { blocked.push(epc); return; }
          box.checked = true;
          matched++;
        });
        refreshGroup("equipment");
        if (pasteOut) {
          var parts = ["已揀選 " + matched + " 件"];
          if (blocked.length) parts.push(blocked.length + " 件不可借出");
          if (unknown.length) parts.push("未登記:" + unknown.slice(0, 3).join(", ") + (unknown.length > 3 ? "…" : ""));
          pasteOut.textContent = parts.join(";");
        }
      });
    }
  }
})();
