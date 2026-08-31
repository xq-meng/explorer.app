(() => {
  const root = document.documentElement;
  const storageKey = "explorer-lang";
  const shotKey = "explorer-shot";

  const meta = {
    en: {
      title: "Explorer.app — a native macOS file manager",
      description:
        "A native macOS file manager with Windows Explorer-style navigation: tabs, a location sidebar, a path bar, and a details list, plus Quick Look, Trash, and Command shortcuts.",
    },
    zh: {
      title: "Explorer.app — 原生 macOS 文件管理器",
      description:
        "原生 macOS 文件管理器，采用 Windows 资源管理器式导航：标签页、位置侧边栏、路径栏和详细信息列表，同时支持 Quick Look、废纸篓和 Command 快捷键。",
    },
  };

  function preferredLang() {
    const stored = localStorage.getItem(storageKey);
    if (stored === "en" || stored === "zh") return stored;
    return (navigator.language || "en").toLowerCase().startsWith("zh") ? "zh" : "en";
  }

  function setLang(lang) {
    const next = lang === "zh" ? "zh" : "en";
    root.lang = next;
    localStorage.setItem(storageKey, next);
    document.title = meta[next].title;
    const description = document.querySelector('meta[name="description"]');
    if (description) description.setAttribute("content", meta[next].description);
    document.querySelectorAll("[data-lang-button]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.langButton === next));
    });
  }

  function setShot(mode) {
    const next = mode === "dark" ? "dark" : "light";
    localStorage.setItem(shotKey, next);
    document.querySelectorAll("[data-shot]").forEach((img) => {
      img.classList.toggle("is-hidden", img.dataset.shot !== next);
    });
    document.querySelectorAll("[data-shot-button]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.shotButton === next));
    });
  }

  function preferredShot() {
    const stored = localStorage.getItem(shotKey);
    if (stored === "light" || stored === "dark") return stored;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  async function copyText(text, button) {
    const original = button.innerHTML;
    const copied = root.lang === "zh" ? "已复制" : "Copied";
    const failed = root.lang === "zh" ? "复制失败" : "Copy failed";
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = copied;
    } catch {
      button.textContent = failed;
    }
    window.setTimeout(() => {
      button.innerHTML = original;
    }, 1600);
  }

  document.querySelectorAll("[data-lang-button]").forEach((button) => {
    button.addEventListener("click", () => setLang(button.dataset.langButton));
  });

  document.querySelectorAll("[data-shot-button]").forEach((button) => {
    button.addEventListener("click", () => setShot(button.dataset.shotButton));
  });

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", () => copyText(button.dataset.copy, button));
  });

  setLang(preferredLang());
  setShot(preferredShot());
})();
