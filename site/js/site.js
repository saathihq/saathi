//
//  site.js
//  saathi.dev
//
//  Progressive enhancement only. Everything on this page works with JavaScript
//  switched off — this file marks the section you are currently reading in the
//  side rail, and nothing else. If it fails to load, the rail is still a working
//  list of links to the five sections.
//

(function () {
  "use strict";

  var steps = Array.prototype.slice.call(document.querySelectorAll(".rail__step"));
  var sections = steps
    .map(function (step) {
      return document.querySelector(step.getAttribute("href"));
    })
    .filter(Boolean);

  if (steps.length === 0 || sections.length !== steps.length) return;
  if (typeof IntersectionObserver !== "function") return;

  function markCurrent(index) {
    steps.forEach(function (step, i) {
      // `aria-current` rather than a class alone: a screen-reader user moving
      // through the rail should hear which section they are in, not just see it.
      if (i === index) {
        step.setAttribute("aria-current", "true");
      } else {
        step.removeAttribute("aria-current");
      }
    });
  }

  var visible = new Map();

  var observer = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        visible.set(entry.target, entry.isIntersecting ? entry.intersectionRatio : 0);
      });

      var best = -1;
      var bestRatio = 0;
      sections.forEach(function (section, i) {
        var ratio = visible.get(section) || 0;
        if (ratio > bestRatio) {
          bestRatio = ratio;
          best = i;
        }
      });

      if (best >= 0) markCurrent(best);
    },
    // A band across the middle of the viewport, so "current" means "what you are
    // actually reading" rather than "what has just touched the top edge".
    { rootMargin: "-45% 0px -45% 0px", threshold: [0, 0.01, 0.5, 1] }
  );

  sections.forEach(function (section) {
    observer.observe(section);
  });
})();
