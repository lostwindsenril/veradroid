(function () {
  function b64uToBuf(s) {
    s = s.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var bin = atob(s), out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  }
  function bufToB64u(buf) {
    var bytes = new Uint8Array(buf), s = '';
    for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function setStatus(id, msg) {
    var el = document.getElementById(id || 'pk-status');
    if (el) el.textContent = msg;
  }

  async function doLogin(scope, statusId) {
    if (!window.PublicKeyCredential) {
      setStatus(statusId, '当前浏览器不支持通行密钥（请使用 Chrome / Safari / Edge 最新版）');
      return;
    }
    try {
      setStatus(statusId, '正在唤起系统通行密钥验证…');
      var r1 = await fetch('/api/passkey/login/options', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ scope: scope || 'user' })
      });
      var j1 = await r1.json();
      if (!j1.ok) { setStatus(statusId, j1.error || '无法发起验证'); return; }
      var opts = j1.options;
      opts.challenge = b64uToBuf(opts.challenge);
      if (opts.allowCredentials) {
        opts.allowCredentials = opts.allowCredentials.map(function (c) {
          c.id = b64uToBuf(c.id); return c;
        });
      }
      var cred = await navigator.credentials.get({ publicKey: opts });
      var payload = {
        id: cred.id,
        rawId: bufToB64u(cred.rawId),
        type: cred.type,
        response: {
          authenticatorData: bufToB64u(cred.response.authenticatorData),
          clientDataJSON: bufToB64u(cred.response.clientDataJSON),
          signature: bufToB64u(cred.response.signature),
          userHandle: cred.response.userHandle ? bufToB64u(cred.response.userHandle) : null
        }
      };
      setStatus(statusId, '正在校验通行密钥…');
      var r2 = await fetch('/api/passkey/login/verify', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cid: j1.cid, credential: payload })
      });
      var j2 = await r2.json();
      if (j2.ok && j2.redirect) {
        setStatus(statusId, '验证通过，正在进入…');
        window.location.href = j2.redirect;
      } else {
        setStatus(statusId, j2.error || '通行密钥验证失败');
      }
    } catch (e) {
      setStatus(statusId, e && e.name === 'NotAllowedError' ? '已取消通行密钥验证' : ('验证出错：' + (e && e.message ? e.message : e)));
    }
  }

  async function doRegister(label, statusId) {
    if (!window.PublicKeyCredential) {
      setStatus(statusId, '当前浏览器不支持通行密钥');
      return;
    }
    try {
      setStatus(statusId, '请在系统弹窗中完成指纹/面容确认…');
      var r1 = await fetch('/api/passkey/register/options', { method: 'POST' });
      var j1 = await r1.json();
      if (!j1.ok) { setStatus(statusId, j1.error || '无法创建通行密钥'); return; }
      var opts = j1.options;
      opts.challenge = b64uToBuf(opts.challenge);
      opts.user.id = b64uToBuf(opts.user.id);
      if (opts.excludeCredentials) {
        opts.excludeCredentials = opts.excludeCredentials.map(function (c) {
          c.id = b64uToBuf(c.id); return c;
        });
      }
      var cred = await navigator.credentials.create({ publicKey: opts });
      var payload = {
        id: cred.id,
        rawId: bufToB64u(cred.rawId),
        type: cred.type,
        response: {
          attestationObject: bufToB64u(cred.response.attestationObject),
          clientDataJSON: bufToB64u(cred.response.clientDataJSON)
        }
      };
      var r2 = await fetch('/api/passkey/register/verify', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ cid: j1.cid, label: label || (navigator.platform || '我的设备'), credential: payload })
      });
      var j2 = await r2.json();
      if (j2.ok) {
        setStatus(statusId, '通行密钥绑定成功！下次可直接指纹/面容一键登录。');
        setTimeout(function () { window.location.reload(); }, 900);
      } else {
        setStatus(statusId, j2.error || '绑定失败');
      }
    } catch (e) {
      setStatus(statusId, e && e.name === 'NotAllowedError' ? '已取消绑定' : ('绑定出错：' + (e && e.message ? e.message : e)));
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('[data-passkey-login]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        doLogin(btn.getAttribute('data-passkey-login'), btn.getAttribute('data-status') || 'pk-status');
      });
    });
    document.querySelectorAll('[data-passkey-register]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var inp = document.getElementById(btn.getAttribute('data-label-input') || '');
        doRegister(inp ? inp.value : '', btn.getAttribute('data-status') || 'pk-reg-status');
      });
    });
  });
})();
