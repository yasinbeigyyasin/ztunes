/** WebView zoom is controlled by Android's text/display settings, not the desktop window API. */
const noOp = async () => {};
export const getCurrentWebview = (): any => ({ setZoom: noOp, getZoom: async () => 1 });
