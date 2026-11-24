/** Desktop-window API stubs. Android uses the OS activity and the responsive mobile shell instead. */
const noOp = async () => {};
const off = async () => () => {};
const currentWindow: any = {
	label: 'main',
	startDragging: noOp,
	minimize: noOp,
	close: noOp,
	setFocus: noOp,
	setSize: noOp,
	setPosition: noOp,
	setFullscreen: noOp,
	setDecorations: noOp,
	setResizable: noOp,
	setAlwaysOnTop: noOp,
	setTitle: noOp,
	toggleMaximize: noOp,
	isMaximized: async () => false,
	isFullscreen: async () => false,
	isVisible: async () => true,
	onFocusChanged: off,
	onResized: off,
	onMoved: off,
	onCloseRequested: off
};
export const getCurrentWindow = (): any => currentWindow;
