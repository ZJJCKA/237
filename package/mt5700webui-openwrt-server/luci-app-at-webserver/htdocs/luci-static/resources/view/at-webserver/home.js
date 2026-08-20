'use strict';
'require view';

return view.extend({
	render: function() {
		return E('div', { 'class': 'cbi-map' }, [
			E('iframe', {
				'class': 'at-webserver-webui',
				'src': '/5700/',
				'title': _('5G 模块管理界面'),
				'loading': 'eager',
				'style': 'display:block; width:100%; height:calc(100vh - 10rem); height:calc(100dvh - 10rem); min-height:480px; border:0; background:#fff;'
			})
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
