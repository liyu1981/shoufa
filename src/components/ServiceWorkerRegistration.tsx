import { useEffect } from "react";

export function ServiceWorkerRegistration() {
  useEffect(() => {
    if (import.meta.env.PROD && "serviceWorker" in navigator) {
      navigator.serviceWorker
        .register("/sw.js", { updateViaCache: "none" })
        .then((registration) => {
          console.log("[SW] Registered:", registration.scope);
          // Pick up a new service worker promptly after a deployment.
          registration.update().catch(() => undefined);
        })
        .catch((error) => {
          console.error("[SW] Registration failed:", error);
        });
    }
  }, []);

  return null;
}
