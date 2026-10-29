// COI is retained for page runtimes; the worker and JSPI do not require it.
export async function bootstrap(entry, compiler) {
  if (!crossOriginIsolated) {
    if (!('serviceWorker' in navigator)) throw Error('Service workers unavailable');
    await navigator.serviceWorker.register('./coi-serviceworker.js', {scope: './'});
    await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) {
      await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, {once: true}));
    }
    const key = 'monty-coi-reload';
    if (!sessionStorage.getItem(key)) {
      sessionStorage.setItem(key, '1'); location.reload(); return;
    }
    throw Error('Cross-origin isolation unavailable after service-worker reload');
  }
  sessionStorage.removeItem('monty-coi-reload');
  if (compiler === 'js') {
    await new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = `${entry}.js`; script.onload = resolve; script.onerror = reject;
      document.body.append(script);
    });
  } else {
    const {compileStreaming} = await import(`./${entry}.mjs`);
    const app = await compileStreaming(fetch(`${entry}.wasm`));
    const instance = await app.instantiate({}); instance.invokeMain();
  }
}
