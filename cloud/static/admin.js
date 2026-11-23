(function () {
  var state = { days: 7, res: 'apps', page: 1, per: 20, q: '', status: '', selected: new Set() };

  function toast(msg, isErr) {
    var box = document.getElementById('adm-toast');
    if (!box) return;
    var el = document.createElement('div');
    el.className = 'a-toast' + (isErr ? ' err' : '');
    el.textContent = msg;
    box.appendChild(el);
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, 3200);
  }

  async function api(url, opts) {
    var r = await fetch(url, opts || {});
    var j = await r.json();
    if (!r.ok || !j.ok) throw new Error(j.error || ('HTTP ' + r.status));
    return j;
  }

  function fmtBytes(b) {
    b = Number(b || 0);
    if (b >= 1073741824) return (b / 1073741824).toFixed(2) + ' GB';
    if (b >= 1048576) return (b / 1048576).toFixed(1) + ' MB';
    if (b >= 1024) return (b / 1024).toFixed(0) + ' KB';
    return b + ' B';
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c];
    });
  }

  function drawTrend(trend) {
    var cvs = document.getElementById('adm-chart');
    if (!cvs) return;
    var dpr = window.devicePixelRatio || 1;
    var w = cvs.clientWidth || 640, h = cvs.clientHeight || 220;
    cvs.width = w * dpr; cvs.height = h * dpr;
    var ctx = cvs.getContext('2d');
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, w, h);
    var labels = trend.labels || [], counts = trend.counts || [], mbs = trend.mb || [];
    var n = labels.length || 1;
    var maxC = Math.max.apply(null, counts.concat([5]));
    var maxM = Math.max.apply(null, mbs.concat([1]));
    var padL = 40, padR = 16, padT = 18, padB = 28;
    var gw = w - padL - padR, gh = h - padT - padB;

    // Grid lines
    ctx.strokeStyle = '#e4e4e7'; ctx.lineWidth = 1;
    for (var g = 0; g <= 4; g++) {
      var gy = padT + (gh * g / 4);
      ctx.beginPath(); ctx.moveTo(padL, gy); ctx.lineTo(w - padR, gy); ctx.stroke();
    }
    // Bars = download counts
    var bw = Math.max(4, Math.min(28, (gw / n) * 0.55));
    for (var i = 0; i < n; i++) {
      var x = padL + (gw * (i + 0.5) / n);
      var bh = (counts[i] / maxC) * gh;
      ctx.fillStyle = '#18181b';
      ctx.fillRect(x - bw / 2, padT + gh - bh, bw, bh);
      if (n <= 10 || i % Math.ceil(n / 8) === 0 || i === n - 1) {
        ctx.fillStyle = '#71717a'; ctx.font = '11px sans-serif'; ctx.textAlign = 'center';
        ctx.fillText(labels[i], x, h - 8);
      }
    }
    // Line = traffic MB
    ctx.strokeStyle = '#059669'; ctx.lineWidth = 2; ctx.beginPath();
    for (var j = 0; j < n; j++) {
      var lx = padL + (gw * (j + 0.5) / n);
      var ly = padT + gh - (mbs[j] / maxM) * gh;
      if (j === 0) ctx.moveTo(lx, ly); else ctx.lineTo(lx, ly);
    }
    ctx.stroke();
    ctx.fillStyle = '#71717a'; ctx.font = '11px sans-serif'; ctx.textAlign = 'left';
    ctx.fillText('柱: 下载次数(峰 ' + maxC + ')  线: 流量 MB(峰 ' + maxM.toFixed(1) + ' MB)', padL, 12);
  }

  async function loadOverview() {
    if (!document.getElementById('kpi-dl')) return;
    try {
      var d = await api('/api/admin/overview?days=' + state.days);
      var k = d.kpis;
      document.getElementById('kpi-dl').textContent = k.dl_today + ' / ' + k.dl_total;
      document.getElementById('kpi-bytes').textContent = fmtBytes(k.bytes_today) + ' / ' + fmtBytes(k.bytes_total);
      document.getElementById('kpi-dev').textContent = k.bound + ' / ' + k.devices;
      document.getElementById('kpi-pending').textContent = (k.pending_uploads + k.pending_requests) + ' 项';
      document.getElementById('kpi-pending-sub').textContent = '待审上传 ' + k.pending_uploads + ' · 适配申请 ' + k.pending_requests + ' · 拉黑 IP ' + k.blocked_ips;
      drawTrend(d.trend);

      var ipBody = document.getElementById('top-ips-body');
      ipBody.innerHTML = d.top_ips.length ? d.top_ips.map(function (r) {
        return '<tr><td class="a-mono">' + esc(r.ip) + '</td><td><b>' + r.cnt + '</b></td><td>' + r.mb + ' MB</td><td>' +
          (r.blocked ? '<button class="a-btn sm" data-unblock-ip="' + esc(r.ip) + '">解除拉黑</button>'
                     : '<button class="a-btn sm danger" data-block-ip="' + esc(r.ip) + '">拉黑 IP</button>') +
          '</td></tr>';
      }).join('') : '<tr><td colspan="4" class="a-muted">暂无下载记录</td></tr>';

      var uBody = document.getElementById('top-users-body');
      uBody.innerHTML = d.top_users.length ? d.top_users.map(function (r) {
        return '<tr><td><b>' + esc(r.username) + '</b></td><td>' + r.cnt + '</td><td>' + r.mb + ' MB</td><td>' +
          (r.is_admin ? '<span class="a-badge dark">管理员</span>'
                      : '<button class="a-btn sm ' + (r.active ? 'danger' : '') + '" data-toggle-user="' + r.id + '">' + (r.active ? '封禁' : '解封') + '</button>') +
          '</td></tr>';
      }).join('') : '<tr><td colspan="4" class="a-muted">暂无用户下载排行</td></tr>';
    } catch (e) {
      toast('加载监控大盘失败: ' + e.message, true);
    }
  }

  async function loadTable() {
    var head = document.getElementById('tbl-head'), body = document.getElementById('tbl-body');
    if (!head || !body) return;
    state.selected.clear();
    try {
      var url = '/api/admin/list/' + state.res + '?page=' + state.page + '&per=' + state.per +
                '&q=' + encodeURIComponent(state.q) + '&status=' + encodeURIComponent(state.status);
      var d = await api(url);
      document.getElementById('pager-info').textContent = '共 ' + d.total + ' 条 · 第 ' + d.page + ' / ' + d.pages + ' 页';
      document.getElementById('btn-prev').disabled = d.page <= 1;
      document.getElementById('btn-next').disabled = d.page >= d.pages;

      if (state.res === 'apps') {
        head.innerHTML = '<tr><th><input type="checkbox" id="chk-all"></th><th>ID</th><th>名称 / 包名</th><th>版本</th><th>大小</th><th>状态</th><th>操作</th></tr>';
        body.innerHTML = d.items.map(function (r) {
          return '<tr><td><input type="checkbox" class="row-chk" value="' + r.id + '"></td><td>' + r.id + '</td><td><b>' + esc(r.name) + '</b><div class="a-mono">' + esc(r.package) + '</div></td><td>' + esc(r.version_name) + '</td><td>' + fmtBytes(r.size) + '</td><td><span class="a-badge ' + (r.active ? 'ok' : 'err') + '">' + (r.active ? '上架' : '下架') + '</span></td><td><button class="a-btn sm" data-toggle-app="' + r.id + '">' + (r.active ? '下架' : '上架') + '</button></td></tr>';
        }).join('');
      } else if (state.res === 'fonts') {
        head.innerHTML = '<tr><th>ID</th><th>字体名称</th><th>文件名</th><th>大小</th><th>状态</th><th>时间</th></tr>';
        body.innerHTML = d.items.map(function (r) {
          return '<tr><td>' + r.id + '</td><td><b>' + esc(r.name) + '</b></td><td class="a-mono">' + esc(r.file) + '</td><td>' + fmtBytes(r.size) + '</td><td><span class="a-badge ' + (r.status === 'approved' ? 'ok' : '') + '">' + esc(r.status) + '</span></td><td>' + esc((r.created_at || '').slice(0, 10)) + '</td></tr>';
        }).join('');
      } else if (state.res === 'users') {
        head.innerHTML = '<tr><th><input type="checkbox" id="chk-all"></th><th>ID</th><th>用户名</th><th>邮箱</th><th>角色</th><th>状态</th><th>操作</th></tr>';
        body.innerHTML = d.items.map(function (r) {
          return '<tr><td>' + (r.is_admin ? '' : '<input type="checkbox" class="row-chk" value="' + r.id + '">') + '</td><td>' + r.id + '</td><td><b>' + esc(r.username) + '</b></td><td class="a-mono">' + esc(r.email) + '</td><td>' + (r.is_admin ? '<span class="a-badge dark">管理员</span>' : '普通用户') + '</td><td><span class="a-badge ' + (r.active ? 'ok' : 'err') + '">' + (r.active ? '正常' : '已封禁') + '</span></td><td>' + (r.is_admin ? '—' : '<button class="a-btn sm ' + (r.active ? 'danger' : '') + '" data-toggle-user="' + r.id + '">' + (r.active ? '封禁' : '解封') + '</button>') + '</td></tr>';
        }).join('');
      } else if (state.res === 'devices') {
        head.innerHTML = '<tr><th>ID</th><th>设备标识</th><th>绑定账号</th><th>机型 / 版本</th><th>最近 IP</th><th>最后在线</th></tr>';
        body.innerHTML = d.items.map(function (r) {
          return '<tr><td>' + r.id + '</td><td class="a-mono">' + esc((r.device_id || '').slice(0, 16)) + '</td><td>' + esc(r.username || '未绑定') + '</td><td>' + esc((r.model || 'Kindle') + ' · ' + (r.version_name || '')) + '</td><td class="a-mono">' + esc(r.ip || '—') + '</td><td>' + esc((r.last_seen || '—').slice(0, 16).replace('T', ' ')) + '</td></tr>';
        }).join('');
      } else if (state.res === 'topics') {
        head.innerHTML = '<tr><th><input type="checkbox" id="chk-all"></th><th>ID</th><th>标题</th><th>分区 / 作者</th><th>标记</th><th>治理</th></tr>';
        body.innerHTML = d.items.map(function (r) {
          var badges = (r.pinned ? '<span class="a-badge">置顶</span> ' : '') + (r.featured ? '<span class="a-badge dark">精华</span> ' : '') + (r.locked ? '<span class="a-badge err">已锁</span>' : '');
          return '<tr><td><input type="checkbox" class="row-chk" value="' + r.id + '"></td><td>#' + r.id + '</td><td><a href="/community/t/' + r.id + '" target="_blank">' + esc(r.title) + '</a></td><td>' + esc(r.category_name + ' · ' + r.username) + '</td><td>' + (badges || '—') + '</td><td>' +
            '<button class="a-btn sm" data-mod-topic="' + r.id + '" data-act="pin">置顶</button> ' +
            '<button class="a-btn sm" data-mod-topic="' + r.id + '" data-act="feature">加精</button> ' +
            '<button class="a-btn sm" data-mod-topic="' + r.id + '" data-act="lock">锁帖</button> ' +
            '<button class="a-btn sm danger" data-mod-topic="' + r.id + '" data-act="delete">删除</button></td></tr>';
        }).join('');
      } else if (state.res === 'downloads') {
        head.innerHTML = '<tr><th>ID</th><th>类型</th><th>资源名称</th><th>流量</th><th>用户</th><th>真实 IP</th><th>时间</th></tr>';
        body.innerHTML = d.items.map(function (r) {
          return '<tr><td>' + r.id + '</td><td><span class="a-badge">' + esc(r.kind) + '</span></td><td>' + esc(r.item_name) + '</td><td>' + fmtBytes(r.bytes) + '</td><td>' + esc(r.username) + '</td><td class="a-mono">' + esc(r.ip) + '</td><td>' + esc((r.created_at || '').slice(0, 16).replace('T', ' ')) + '</td></tr>';
        }).join('');
      } else if (state.res === 'blocked_ips') {
        head.innerHTML = '<tr><th>IP 地址</th><th>封禁原因</th><th>时间</th><th>操作</th></tr>';
        body.innerHTML = d.items.map(function (r) {
          return '<tr><td class="a-mono"><b>' + esc(r.ip) + '</b></td><td>' + esc(r.reason) + '</td><td>' + esc((r.created_at || '').slice(0, 16).replace('T', ' ')) + '</td><td><button class="a-btn sm" data-unblock-ip="' + esc(r.ip) + '">解除拉黑</button></td></tr>';
        }).join('');
      }
      if (!d.items.length) body.innerHTML = '<tr><td colspan="7" style="text-align:center;color:#71717a;padding:24px">暂无匹配数据</td></tr>';
      var chkAll = document.getElementById('chk-all');
      if (chkAll) chkAll.addEventListener('change', function () {
        document.querySelectorAll('.row-chk').forEach(function (c) { c.checked = chkAll.checked; });
      });
    } catch (e) {
      toast('加载列表失败: ' + e.message, true);
    }
  }

  async function loadOpsSettings() {
    if (!document.getElementById('ops-bind-dl')) return;
    try {
      var d = await api('/api/admin/settings');
      var s = d.settings;
      document.getElementById('ops-bind-dl').value = s.require_bind_download;
      document.getElementById('ops-bind-ota').value = s.require_bind_ota;
      document.getElementById('ops-dl-lim').value = s.rate_limit_dl_hour;
      document.getElementById('ops-sign-lim').value = s.rate_limit_sign_hour;
      if (document.getElementById('ops-max-dev')) document.getElementById('ops-max-dev').value = s.max_devices_per_user || 5;
      document.getElementById('ops-banner').value = s.site_banner;
    } catch (e) { }
  }

  document.addEventListener('DOMContentLoaded', function () {
    var colBtn = document.getElementById('adm-collapse');
    if (colBtn) colBtn.addEventListener('click', function () {
      document.querySelector('.adm-shell').classList.toggle('collapsed');
    });

    document.querySelectorAll('[data-days]').forEach(function (b) {
      b.addEventListener('click', function () {
        state.days = Number(b.getAttribute('data-days'));
        document.querySelectorAll('[data-days]').forEach(function (x) { x.classList.remove('primary'); });
        b.classList.add('primary');
        loadOverview();
      });
    });

    document.querySelectorAll('[data-res]').forEach(function (b) {
      b.addEventListener('click', function () {
        state.res = b.getAttribute('data-res'); state.page = 1; state.status = '';
        document.querySelectorAll('[data-res]').forEach(function (x) { x.classList.remove('active'); });
        b.classList.add('active');
        loadTable();
      });
    });

    var searchBtn = document.getElementById('btn-search');
    if (searchBtn) searchBtn.addEventListener('click', function () {
      state.q = document.getElementById('tbl-q').value.trim();
      state.per = Number(document.getElementById('tbl-per').value || 20);
      state.page = 1;
      loadTable();
    });
    var prevBtn = document.getElementById('btn-prev'), nextBtn = document.getElementById('btn-next');
    if (prevBtn) prevBtn.addEventListener('click', function () { if (state.page > 1) { state.page--; loadTable(); } });
    if (nextBtn) nextBtn.addEventListener('click', function () { state.page++; loadTable(); });

    var batchBtn = document.getElementById('btn-batch');
    if (batchBtn) batchBtn.addEventListener('click', async function () {
      var act = document.getElementById('batch-act').value;
      var ids = Array.from(document.querySelectorAll('.row-chk:checked')).map(function (c) { return Number(c.value); });
      if (!act || !ids.length) { toast('请先勾选项目并选择批量动作', true); return; }
      try {
        var r = await api('/api/admin/batch', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ resource: state.res, action: act, ids: ids }) });
        toast('批量操作成功（' + r.count + ' 项）');
        loadTable(); loadOverview();
      } catch (e) { toast(e.message, true); }
    });

    var saveOps = document.getElementById('btn-ops-save');
    if (saveOps) saveOps.addEventListener('click', async function () {
      try {
        await api('/api/admin/settings', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            require_bind_download: document.getElementById('ops-bind-dl').value,
            require_bind_ota: document.getElementById('ops-bind-ota').value,
            rate_limit_dl_hour: document.getElementById('ops-dl-lim').value,
            rate_limit_sign_hour: document.getElementById('ops-sign-lim').value,
            max_devices_per_user: document.getElementById('ops-max-dev') ? document.getElementById('ops-max-dev').value : 5,
            site_banner: document.getElementById('ops-banner').value
          })
        });
        toast('运维配置已实时生效（无需重启服务）');
      } catch (e) { toast(e.message, true); }
    });

    document.body.addEventListener('click', async function (ev) {
      var t = ev.target;
      if (t.hasAttribute('data-block-ip')) {
        try {
          await api('/api/admin/ip/block', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ip: t.getAttribute('data-block-ip'), reason: '后台一键拉黑' }) });
          toast('已拉黑 IP: ' + t.getAttribute('data-block-ip'));
          loadOverview(); if (state.res === 'blocked_ips') loadTable();
        } catch (e) { toast(e.message, true); }
      } else if (t.hasAttribute('data-unblock-ip')) {
        try {
          await api('/api/admin/ip/unblock', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ip: t.getAttribute('data-unblock-ip') }) });
          toast('已解除拉黑: ' + t.getAttribute('data-unblock-ip'));
          loadOverview(); if (state.res === 'blocked_ips') loadTable();
        } catch (e) { toast(e.message, true); }
      } else if (t.hasAttribute('data-toggle-user')) {
        try {
          var r = await api('/api/admin/user/' + t.getAttribute('data-toggle-user') + '/toggle', { method: 'POST' });
          toast(r.active ? '已解封账号' : '已封禁账号');
          loadOverview(); if (state.res === 'users') loadTable();
        } catch (e) { toast(e.message, true); }
      } else if (t.hasAttribute('data-toggle-app')) {
        try {
          var ra = await api('/api/admin/app/' + t.getAttribute('data-toggle-app') + '/toggle', { method: 'POST' });
          toast(ra.active ? '应用已上架' : '应用已下架');
          loadTable(); loadOverview();
        } catch (e) { toast(e.message, true); }
      } else if (t.hasAttribute('data-mod-topic')) {
        try {
          var act = t.getAttribute('data-act');
          if (act === 'delete' && !confirm('确认永久删除该帖？')) return;
          await api('/api/admin/topic/' + t.getAttribute('data-mod-topic') + '/moderate', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: act }) });
          toast('社区治理操作已完成');
          loadTable();
        } catch (e) { toast(e.message, true); }
      }
    });

    loadOverview();
    loadTable();
    loadOpsSettings();
  });
})();
