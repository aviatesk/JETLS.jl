// Shows the hovers of the `@diagnostics` code blocks rendered by `docs/diagnostics-block.jl`
(function () {
  const TARGET = ".jetls-diagnostics [data-diagnostics], .jetls-diagnostics [data-related]";
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
    const [kind, ids] = target.dataset.diagnostics !== undefined
      ? ["diagnostic", target.dataset.diagnostics]
      : ["related", target.dataset.related];
    for (const id of ids.split(" ")) {
      const template = block.querySelector(`template[data-${kind}="${id}"]`);
      if (template !== null) element.appendChild(template.content.cloneNode(true));
    }
    element.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    element.addEventListener("mouseleave", scheduleHide);
    block.appendChild(element);
    hover = { target, element };

    const blockRect = block.getBoundingClientRect();
    const rect = target.getBoundingClientRect();
    const left = rect.left - blockRect.left;
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

  // The copy button of Documenter copies the `innerText` of the code block in its click
  // handler, around which the messages are hidden, so that it copies only the code
  function copyingBlock(event) {
    return event.target.closest(".copy-button")?.closest(".jetls-diagnostics") ?? null;
  }
  document.addEventListener("click", (event) => {
    copyingBlock(event)?.classList.add("jetls-diagnostics-copying");
  }, true);
  document.addEventListener("click", (event) => {
    copyingBlock(event)?.classList.remove("jetls-diagnostics-copying");
  });
})();
