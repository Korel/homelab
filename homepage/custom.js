const baseDomain = 'korel.be.eu.org';
const environments = ['ts', 'l'];
const currentHost = window.location.hostname;
const activeEnv = environments.find(env => currentHost.includes(env));

const rewriteLinks = () => {
    if (!activeEnv) return;

    const serviceLinks = document.querySelectorAll('.service-card a, .bookmark-card a');
    serviceLinks.forEach(link => {
        try {
            if (!link.href) return;
            if (link.dataset.rewritten) return;

            const url = new URL(link.href);
            if (!url.hostname.includes(`${activeEnv}.${baseDomain}`)) {
                const newHostname = url.hostname.replace(/\.[^.]+\.korel/, `.${activeEnv}.korel`);
                url.hostname = newHostname;
                link.href = url.toString();
                link.dataset.rewritten = "true";
            }
        } catch (e) {
            console.debug('Skipped invalid URL:', link.href);
        }
    });
};

if (activeEnv) {
    console.log(`Homepage: Detected environment '${activeEnv}', rewriting links...`);
    
    rewriteLinks();

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', rewriteLinks);
    }

    const observer = new MutationObserver(() => {
        rewriteLinks();
    });
    
    const startObserver = () => {
        if (document.body) {
            observer.observe(document.body, { childList: true, subtree: true });
            rewriteLinks();
        } else {
            setTimeout(startObserver, 50);
        }
    };
    startObserver();

} else {
    console.log('Homepage: No matching environment detected, no link rewriting performed.');
}