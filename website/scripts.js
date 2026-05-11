// SecVF site — minimal, no external deps, CSP-friendly.
(() => {
  "use strict";

  const yearEl = document.getElementById("year");
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());

  // Fade-in on scroll for major sections (respects prefers-reduced-motion)
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reduce && "IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      }
    }, { threshold: 0.12 });
    document.querySelectorAll(".feature, .how-card, .spec, .dl-card, .trust-card").forEach((el) => {
      el.classList.add("reveal");
      io.observe(el);
    });
  }
})();
