// Shows the hovers of the `@diagnostics` code blocks rendered by `docs/diagnostics-block.jl`
(function () {
  const TARGET = ".jetls-diagnostics [data-diagnostics]";
  let hover = null;
  let hideTimer = null;

  function hide() {
    clearTimeout(hideTimer);
    if (hover !== null) {
      hover.element.remove();
      hover = null;
    }
  }

  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(hide, 300);
  }

  function show(target) {
    clearTimeout(hideTimer);
    if (hover !== null && hover.target === target) return;
    hide();
    const block = target.closest(".jetls-diagnostics");
    const element = document.createElement("div");
    element.className = "jetls-diagnostic-hover";
    for (const id of target.dataset.diagnostics.split(" ")) {
      const template = block.querySelector(`template[data-diagnostic="${id}"]`);
      if (template !== null) element.appendChild(template.content.cloneNode(true));
    }
    element.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    element.addEventListener("mouseleave", scheduleHide);
    block.appendChild(element);
    hover = { target, element };

    const blockRect = block.getBoundingClientRect();
    const rect = target.getBoundingClientRect();
    const left = rect.left + parseFloat(getComputedStyle(target).paddingLeft) - blockRect.left;
    element.style.top = `${rect.bottom - blockRect.top + 2}px`;
    element.style.left = `${Math.max(0, Math.min(left, blockRect.width - element.offsetWidth))}px`;
  }

  document.addEventListener("mouseover", (event) => {
    const target = event.target.closest(TARGET);
    if (target !== null) show(target);
  });
  document.addEventListener("mouseout", (event) => {
    const target = event.target.closest(TARGET);
    if (target !== null && !target.contains(event.relatedTarget)) scheduleHide();
  });
  // Touch devices have no hover
  document.addEventListener("click", (event) => {
    const target = event.target.closest(TARGET);
    if (target !== null) {
      show(target);
    } else if (hover !== null && !hover.element.contains(event.target)) {
      hide();
    }
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") hide();
  });
})();
