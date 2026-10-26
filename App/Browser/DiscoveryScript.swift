import Foundation

enum DiscoveryScript {
    static func source(token: String, controlsOnly: Bool = false) -> String {
        // UUIDs are generated natively; JSON encoding also keeps script interpolation safe.
        let encoded = String(data: try! JSONEncoder().encode(token), encoding: .utf8)!
        return #"""
        (() => {
          'use strict';
          // Sign-in pages are outside media discovery. Do not observe their requests.
          if (location.hostname.toLowerCase() === 'accounts.google.com') return;
          let token = \#(encoded);
          const controlsOnly = \#(controlsOnly ? "true" : "false");
          const handler = window.webkit && window.webkit.messageHandlers[controlsOnly ? 'vyuDownloadAction' : 'vyuMedia'];
          if (!handler) return;
          const seen = new Set();
          const observed = new Map();
          const alternatives = new Map();
          const alternativeGroups = new Set();
          const partialResources = new Map();
          const publishedMetadata = new Map();
          const pendingMetadata = new Map();
          let metadataTimer = null, metadataUpdates = 0;
          const attached = new WeakSet();
          const protectedVideos = new WeakSet();
          const controls = new Map();
          const controlHosts = new WeakSet();
          const sizeObserver = typeof ResizeObserver === 'function' ? new ResizeObserver(scheduleScan) : null;
          let emitted = 0, pending = false, hasBlob = false, hasProtected = false;
          let metadataReaders = 0;
          let historyGeneration = 0, resourceCutoff = 0;
          const metadataByteLimit = 2 * 1024 * 1024;
          const encoder = typeof TextEncoder === 'function' ? new TextEncoder() : null;
          const mediaExtension = /\.(m3u8|mpd|mp4|mov|m4v|webm)(?:$|[?#])/i;
          const mediaMime = /^(video\/|application\/(?:vnd\.apple\.mpegurl|x-mpegurl|dash\+xml)|audio\/(?:x-)?mpegurl)/i;
          function cleanTitle(value) {
            return typeof value === 'string' ? value.slice(0, 1600).replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 240) : '';
          }
          function contentTitle(value) {
            const title = cleanTitle(value);
            // Exact control labels only: a descriptive title that mentions a
            // player or playback still belongs to the video.
            return ['video', 'video player', 'embedded video', 'media player', 'youtube video player',
              'play', 'pause', 'play video', 'pause video', '播放', '暂停', '播放视频', '暂停视频',
              '视频', '影片', '播放器', '视频播放器', '内嵌视频', '嵌入视频',
              '下载', '下载视频', '下载此视频', '点赞', '评论', '分享', '分享给朋友',
              'download', 'download video', 'like', 'comment', 'share'].includes(title.toLowerCase()) ? '' : title;
          }
          const titleSemantic = 'figcaption,[itemprop="name"],[itemprop="description"],[data-testid="tweetText"],h1,h2,h3,h4,h5,h6,[role="heading"]';
          const titleNodeBudget = 256;
          const titleExcluded = 'script,style,template,nav,header,footer,time,button,input,select,textarea,video,[data-vyu-download],[role="button"],[role="toolbar"],[rel~="author"],[rel~="tag"],[itemprop="author"],[itemprop="datePublished"],[itemprop="dateModified"]';
          function titleContext() { return {videos: new WeakMap(), semantic: new WeakMap(), plain: new WeakMap()}; }
          function titleRole(element) {
            return ((element.getAttribute('class') || '') + ' ' + (element.id || '') + ' ' +
              (element.getAttribute('data-testid') || '')).slice(0, 1024).replace(/([a-z])([A-Z])/g, '$1 $2').toLowerCase();
          }
          function titleHint(element) {
            return /(?:^|[\s_-])(?:title|headline|caption|subject)(?:$|[\s_-])/.test(titleRole(element));
          }
          function metadataRole(element) {
            return element.matches(titleExcluded) ||
              /(?:^|[\s_-])(?:author|byline|avatar|username|user-info|profile|timestamp|timeago|metadata|meta|tags?|hashtags?|badge|categories|category|social|engagement|shares?|likes?|comments?|reactions?|actions?|toolbar|controls?|download)(?:$|[\s_-])/.test(titleRole(element));
          }
          function localCard(element) {
            if (element.matches('article,figure,li,[role="article"]')) return true;
            return (element.getAttribute('class') || '').slice(0, 1024).split(/\s+/).some(value =>
              /^(?:(?:video|media|feed|post)[_-])?(?:card|post|entry|item)$/.test(value.toLowerCase()));
          }
          function belongsToVideoScope(element, video, container) {
            let ancestor = element;
            for (let depth = 0; ancestor && ancestor !== container && depth < 16; depth++, ancestor = ancestor.parentElement) {
              if (localCard(ancestor) && !ancestor.contains(video)) return false;
            }
            // A deeply nested or disconnected node is not reliable evidence.
            return ancestor === container;
          }
          function hasDirectMetadata(element, links = false) {
            // An unlabelled author row still commonly contains an avatar or a
            // time element. Only inspect its immediate children, not the card.
            let child = element.firstElementChild;
            for (let count = 0; child && count < 32; count++, child = child.nextElementSibling) {
              if (child.matches('img,time') || (links && child.tagName === 'A')) return true;
            }
            return false;
          }
          function excludedTitleElement(element, context, plain = false) {
            for (let ancestor = element, depth = 0; ancestor && depth < 6; depth++, ancestor = ancestor.parentElement) {
              if (metadataRole(ancestor)) return true;
              if (ancestor !== element && (ancestor === document.body || ancestor === document.documentElement ||
                  ancestor.tagName === 'MAIN' || localCard(ancestor) || boundedVideoCount(ancestor, context) !== 0)) break;
              if (ancestor.hidden || ancestor.getAttribute('aria-hidden') === 'true') return true;
              if (hasDirectMetadata(ancestor, plain && !titleHint(ancestor))) return true;
            }
            return false;
          }
          function plainTitle(value) {
            const title = contentTitle(value);
            if (!title || /^[\d\s.,:;!?+\-–—()（）/|·•]+$/.test(title) ||
                /^(?:[#@]\S+\s*)+$/.test(title) || /^(?:https?:\/\/|www\.)\S+$/i.test(title) ||
                /^(?:\d+\s*(?:秒|分钟|小时|天|周|个月|年)前|\d+\s*(?:s|m|h|d|seconds?|minutes?|hours?|days?|weeks?|months?|years?)(?:\s+ago)?)$/i.test(title)) return '';
            return title;
          }
          function boundedVideoCount(element, context) {
            if (!element) return 0;
            if (element.tagName === 'VIDEO') return 1;
            if (context.videos.has(element)) return context.videos.get(element);
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT);
            let node, visited = 0, count = 0;
            while ((node = walker.nextNode())) {
              // Unknown is deliberately treated like a multi-player container.
              if (++visited > titleNodeBudget) { count = 2; break; }
              if (node.tagName === 'VIDEO' && ++count === 2) break;
            }
            context.videos.set(element, count);
            return count;
          }
          function boundedSemanticNodes(element, context) {
            if (context.semantic.has(element)) return context.semantic.get(element);
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT);
            const nodes = [];
            let node, visited = 0;
            while (nodes.length < 16 && (node = walker.nextNode())) {
              if (++visited > titleNodeBudget) break;
              if ((node.matches(titleSemantic) || titleHint(node)) && boundedVideoCount(node, context) === 0) nodes.push(node);
            }
            context.semantic.set(element, nodes);
            return nodes;
          }
          function boundedPlainNodes(element, context) {
            if (context.plain.has(element)) return context.plain.get(element);
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT);
            const nodes = [];
            let node, visited = 0;
            while ((node = walker.nextNode())) {
              if (++visited > titleNodeBudget) break;
              if (node.matches('div,span,p') && boundedVideoCount(node, context) === 0) nodes.push(node);
            }
            context.plain.set(element, nodes);
            return nodes;
          }
          function plainTextBlock(element, container, context) {
            let block = element;
            for (let depth = 0; depth < 4; depth++) {
              const parent = block.parentElement;
              if (!parent || parent === container || !parent.matches('div,p,span') ||
                  boundedVideoCount(parent, context) !== 0 || excludedTitleElement(parent, context, true)) break;
              // Join formatting spans belonging to one text block, not separate
              // paragraphs, tags, author rows or another nested card.
              let child = parent.firstElementChild, count = 0, inlineOnly = true;
              for (; child && count < 32; count++, child = child.nextElementSibling) {
                if (!child.matches('span,em,strong,b,i,u,s,small,mark,sub,sup,br')) { inlineOnly = false; break; }
              }
              if (child || !inlineOnly) break;
              block = parent;
            }
            return block;
          }
          function belongsToTextBlock(owner, element) {
            let ancestor = owner;
            for (let depth = 0; ancestor && ancestor !== element && depth < 16; depth++, ancestor = ancestor.parentElement) {
              // A wrapper can contain another text-only card even though it has
              // no video. Its descendant title is not this wrapper's caption.
              if (localCard(ancestor)) return false;
            }
            return ancestor === element;
          }
          function titleText(element, explicit = false, context = titleContext()) {
            if (!element || boundedVideoCount(element, context) !== 0) return '';
            const plain = !element.matches(titleSemantic) && !titleHint(element);
            if (!explicit && excludedTitleElement(element, context, plain || element.tagName === 'P')) return '';
            if (!explicit && (element.hidden || element.getAttribute('aria-hidden') === 'true' ||
                getComputedStyle(element).display === 'none' || getComputedStyle(element).visibility === 'hidden')) return '';
            // Count elements as well as text: empty or deeply nested markup must
            // not turn a short caption lookup into an unbounded DOM walk.
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
            let node, text = '', visited = 0, textNodes = 0;
            while ((node = walker.nextNode())) {
              if (++visited > titleNodeBudget) return explicit ? cleanTitle(text) : '';
              if (node.nodeType !== Node.TEXT_NODE) continue;
              if (++textNodes > 64) return explicit ? cleanTitle(text) : '';
              const owner = node.parentElement;
              if (!owner || owner.closest('script,style,template,nav,button,video,[data-vyu-download]')) continue;
              if (!explicit && (!belongsToTextBlock(owner, element) ||
                  excludedTitleElement(owner, context, plain || element.tagName === 'P') ||
                  owner.closest('[hidden],[aria-hidden="true"]'))) continue;
              text += ' ' + node.data.slice(0, 1600);
              if (text.length > 320) return explicit ? cleanTitle(text) : '';
            }
            // A nearby paragraph is useful only when it is a short description;
            // never use a card's full article body as the video's title.
            if (!explicit && text.replace(/\s+/g, ' ').trim().length > 240) return '';
            return explicit ? cleanTitle(text) : plainTitle(text);
          }
          function videoTitle(video, context = titleContext()) {
            const attribute = contentTitle(video.getAttribute('title'));
            if (attribute) return attribute;
            const labelled = (video.getAttribute('aria-labelledby') || '').slice(0, 1024).trim().split(/\s+/).slice(0, 8)
              .map(id => titleText(document.getElementById(id), true, context)).filter(Boolean).join(' ');
            if (contentTitle(labelled)) return contentTitle(labelled);
            const aria = contentTitle(video.getAttribute('aria-label'));
            if (aria) return aria;
            const directText = element => element &&
              (element.matches(titleSemantic) || titleHint(element) || element.tagName === 'P') ? titleText(element, false, context) : '';
            let branch = video;
            for (let depth = 0; branch && depth < 5; depth++, branch = branch.parentElement) {
              const parent = branch.parentElement;
              const boundary = !parent || parent === document.body || parent === document.documentElement || parent.tagName === 'MAIN';
              // Never scan a document-wide container just to find one video's
              // caption. Cached counts live only for this synchronous scan.
              const uniqueParent = !boundary && boundedVideoCount(parent, context) === 1;
              // Immediate semantic siblings can distinguish videos even when
              // they share a container. Stop before another player's content.
              for (const direction of ['previousElementSibling', 'nextElementSibling']) {
                let sibling = branch[direction];
                for (let step = 0; sibling && step < 3; step++, sibling = sibling[direction]) {
                  if (controlHosts.has(sibling)) continue;
                  if (boundedVideoCount(sibling, context) !== 0 || localCard(sibling)) break;
                  const safeSibling = uniqueParent || (direction === 'previousElementSibling' && sibling.matches('h1,h2,h3,h4,h5,h6,[role="heading"]'));
                  const nearby = safeSibling ? directText(sibling) : '';
                  if (nearby) return nearby;
                  if (uniqueParent && (metadataRole(sibling) || hasDirectMetadata(sibling, true))) continue;
                  break;
                }
              }
              if (boundary || !uniqueParent) break;
              const nodes = boundedSemanticNodes(parent, context).filter(node => belongsToVideoScope(node, video, parent));
              const caption = nodes.find(node => node.tagName === 'FIGCAPTION');
              const captionText = titleText(caption, false, context);
              if (captionText) return captionText;
              const descriptions = nodes.filter(node => node.matches('[itemprop="name"],[itemprop="description"],[data-testid="tweetText"]'));
              for (const node of descriptions) { const text = titleText(node, false, context); if (text) return text; }
              const preceding = nodes.filter(node => node.compareDocumentPosition(video) & Node.DOCUMENT_POSITION_FOLLOWING).reverse();
              const following = nodes.filter(node => !(node.compareDocumentPosition(video) & Node.DOCUMENT_POSITION_FOLLOWING));
              for (const node of [...preceding, ...following]) { const text = titleText(node, false, context); if (text) return text; }
              // Plain card titles are often div/span text separated from the
              // player by a tag/source row. Search only before this player and
              // within its single-video container; never borrow a later card.
              const plainNodes = boundedPlainNodes(parent, context).filter(node =>
                belongsToVideoScope(node, video, parent) &&
                (node.compareDocumentPosition(video) & Node.DOCUMENT_POSITION_FOLLOWING)).reverse();
              const checkedBlocks = new Set();
              for (const node of plainNodes) {
                const block = plainTextBlock(node, parent, context);
                if (checkedBlocks.has(block)) continue;
                checkedBlocks.add(block);
                const text = titleText(block, false, context);
                if (text) return text;
              }
              if (localCard(parent)) break;
            }
            const described = (video.getAttribute('aria-describedby') || '').slice(0, 1024).trim().split(/\s+/).slice(0, 8)
              .map(id => titleText(document.getElementById(id), true, context)).filter(Boolean).join(' ');
            return contentTitle(described) || cleanTitle(document.title);
          }
          function post(event, url, source, mime, title) {
            try {
              handler.postMessage({token, documentURL: location.href, event, url: url || '',
                title: cleanTitle(title) || cleanTitle(document.title), source, mime: (mime || '').slice(0, 200)});
            } catch (_) {}
          }
          function emitMetadata(item) {
            if (partialResources.has(item.url) && !['video', 'source'].includes(item.source)) return;
            if (item.event === 'alternative' && hasProtected) return;
            if (item.event === 'candidate') {
              post(item.event, item.url, item.source, item.mime, item.title);
            } else {
              try {
                handler.postMessage({token, documentURL: location.href, event: 'alternative', url: item.url,
                  relatedURL: item.relatedURL, title: item.title || cleanTitle(document.title), source: 'metadata', mime: 'video/mp4'});
              } catch (_) {}
            }
          }
          function flushMetadata() {
            metadataTimer = null;
            const now = performance.now();
            for (const [key, item] of pendingMetadata) {
              const state = publishedMetadata.get(key);
              if (!state || state.signature === item.signature || state.updates >= 8 || metadataUpdates >= 320) {
                pendingMetadata.delete(key); continue;
              }
              if (now - state.time < 500) continue;
              pendingMetadata.delete(key);
              state.signature = item.signature; state.time = now; state.updates++; metadataUpdates++;
              emitMetadata(item);
            }
            if (pendingMetadata.size) metadataTimer = setTimeout(flushMetadata, 500);
          }
          function publishMetadata(event, url, source, mime, title, relatedURL = '') {
            const key = event + '|' + relatedURL + '|' + url;
            const item = {event, url, source, mime: mime || '', title: cleanTitle(title), relatedURL};
            item.signature = JSON.stringify([item.source, item.mime, item.title]);
            const state = publishedMetadata.get(key);
            if (!state) {
              // 160 original candidates plus 160 paired alternatives at most.
              if (publishedMetadata.size >= 320) return;
              publishedMetadata.set(key, {signature: item.signature, time: performance.now(), updates: 0});
              emitMetadata(item); return;
            }
            if (state.signature === item.signature) { pendingMetadata.delete(key); return; }
            if (state.updates >= 8 || metadataUpdates >= 320) return;
            // Coalesce repeated scans and mirrored players without consuming
            // the separate budget for newly discovered URLs. Explicit download
            // clicks read the current DOM and never wait for this queue.
            pendingMetadata.set(key, item);
            if (metadataTimer === null) metadataTimer = setTimeout(flushMetadata, 500);
          }
          function send(event, url, source, mime, title) {
            const key = event + '|' + (url || '');
            if (seen.has(key)) {
              if (event === 'candidate') publishMetadata(event, url, source, mime, title);
              return;
            }
            if (emitted >= 160) return;
            seen.add(key); emitted++;
            if (event === 'candidate') publishMetadata(event, url, source, mime, title);
            else post(event, url, source, mime, title);
          }
          function markProtected(video) {
            protectedVideos.add(video);
            if (!hasProtected) {
              hasProtected = true;
              // Protection is not subject to the discovery candidate budget.
              post('protected', '', 'encrypted', '');
            }
          }
          function observe(value, source, mime, title) {
            if (typeof value !== 'string' || !value || value.length > 8192) return;
            if (value.startsWith('blob:')) {
              hasBlob = true; send('mse', '', source, ''); return;
            }
            try {
              const url = new URL(value, document.baseURI);
              if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return;
              if (/\.(m4s|cmfv|cmfa|ts)(?:$|[?#])/i.test(url.href)) return;
              if (!['video', 'source'].includes(source) && partialResources.has(url.href)) return;
              if (source !== 'video' && source !== 'source' && !mediaExtension.test(url.href) && !mediaMime.test(mime || '')) return;
              const previous = observed.get(url.href);
              const priority = value => value === 'video' ? 3 : value === 'source' ? 2 : 1;
              const preferred = {
                source: previous && priority(previous.source) > priority(source) ? previous.source : source,
                mime: mime || (previous && previous.mime) || '',
                title: previous && priority(previous.source) > priority(source) ? previous.title : cleanTitle(title) || (previous && previous.title) || ''
              };
              if (observed.size < 160 || previous) observed.set(url.href, preferred);
              send('candidate', url.href, preferred.source, preferred.mime, preferred.title);
              if (preferred.title) {
                for (const item of alternatives.values()) {
                  if (item.relatedURL === url.href && item.title !== preferred.title) { item.title = preferred.title; sendAlternative(item); }
                }
              }
            } catch (_) {}
          }
          function alternativeURL(value, extension) {
            if (typeof value !== 'string' || !value || value.length > 8192 || /[\u0000-\u001f\u007f]/.test(value)) return null;
            try {
              // Metadata must contain its actual URL. Do not guess CDN paths or
              // treat unrelated relative values as another video representation.
              const url = new URL(value);
              if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
              if (extension === 'm3u8' && !/\.m3u8$/i.test(url.pathname)) return null;
              if (extension === 'mp4' && /\.[^/.]+$/.test(url.pathname) && !/\.mp4$/i.test(url.pathname)) return null;
              return url.href;
            } catch (_) { return null; }
          }
          function sendAlternative(item) {
            if (hasProtected) return;
            publishMetadata('alternative', item.url, 'metadata', 'video/mp4',
              cleanTitle(item.title) || cleanTitle((observed.get(item.relatedURL) || {}).title) || cleanTitle(document.title), item.relatedURL);
          }
          function rememberAlternatives(playlists, files, title) {
            if (hasProtected) return;
            for (const relatedURL of playlists) {
              if (alternativeGroups.size >= 80 && !alternativeGroups.has(relatedURL)) continue;
              for (const url of files) {
                if (partialResources.has(url)) continue;
                const key = relatedURL + '\n' + url;
                const previous = alternatives.get(key);
                const relatedTitle = cleanTitle(title) || cleanTitle((observed.get(relatedURL) || {}).title);
                if (previous) {
                  if (relatedTitle && previous.title !== relatedTitle) { previous.title = relatedTitle; sendAlternative(previous); }
                  continue;
                }
                if (alternatives.size >= 160) continue;
                const item = {relatedURL, url, title: relatedTitle};
                alternativeGroups.add(relatedURL); alternatives.set(key, item); sendAlternative(item);
              }
            }
          }
          function inspectMetadata(root) {
            if (!encoder || !root || typeof root !== 'object' || hasProtected) return;
            // Validate the complete bounded JSON tree before emitting anything.
            // Keep only pairs from the same exact video_info.variants object;
            // nearby posts, quoted posts and advertisements cannot be combined.
            const stack = [[root, 0]], groups = [];
            let nodes = 0, bytes = 0;
            try {
              while (stack.length) {
                if (++nodes > 12000) return;
                const [value, depth] = stack.pop();
                if (depth > 32) return;
                if (value === null || typeof value !== 'object') {
                  if (!['string', 'number', 'boolean'].includes(typeof value) && value !== null) return;
                  if (typeof value === 'string' && value.length > metadataByteLimit) return;
                  bytes += encoder.encode(JSON.stringify(value)).length + 1;
                } else {
                  if (Array.isArray(value) && value.length > 12000) return;
                  const keys = Object.keys(value);
                  if (keys.length > 12000 || stack.length + keys.length > 12000) return;
                  bytes += 2;
                  for (const key of keys) {
                    if (key.length > metadataByteLimit) return;
                    bytes += encoder.encode(JSON.stringify(key)).length + 2;
                    if (bytes > metadataByteLimit) return;
                    const child = value[key];
                    if (key === 'video_info' && child && typeof child === 'object' && !Array.isArray(child) &&
                        Array.isArray(child.variants) && child.variants.length <= 12 && groups.length < 80) groups.push(child.variants);
                    stack.push([child, depth + 1]);
                  }
                }
                if (bytes > metadataByteLimit) return;
              }
              for (const group of groups) {
                const playlists = [], files = [];
                for (const item of group) {
                  if (!item || typeof item !== 'object' || typeof item.content_type !== 'string') continue;
                  const mime = item.content_type.toLowerCase().split(';')[0].trim();
                  if (['application/x-mpegurl', 'application/vnd.apple.mpegurl'].includes(mime)) {
                    const url = alternativeURL(item.url, 'm3u8');
                    if (url && !playlists.includes(url)) playlists.push(url);
                  } else if (mime === 'video/mp4') {
                    const url = alternativeURL(item.url, 'mp4');
                    if (url && !files.includes(url)) files.push(url);
                  }
                }
                rememberAlternatives(playlists, files);
              }
            } catch (_) {}
          }
          function metadataResponse(urlValue, mime, length) {
            try {
              const url = new URL(urlValue);
              if (url.origin !== location.origin || !['http:', 'https:'].includes(url.protocol) || url.username || url.password) return false;
              const type = (mime || '').toLowerCase().split(';')[0].trim();
              if (type !== 'application/json' && !/^application\/[a-z0-9!#$&^_.+-]+\+json$/.test(type)) return false;
              return !length || (/^\d+$/.test(length) && Number(length) <= metadataByteLimit);
            } catch (_) { return false; }
          }
          function playlistResponse(urlValue, mime, length) {
            try {
              const url = new URL(urlValue);
              if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.href.length > 8192) return false;
              const type = (mime || '').toLowerCase().split(';')[0].trim();
              if (!/\.m3u8$/i.test(url.pathname) && !['application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl', 'audio/x-mpegurl'].includes(type)) return false;
              return !length || (/^\d+$/.test(length) && Number(length) <= metadataByteLimit);
            } catch (_) { return false; }
          }
          function sendPartial(url, item) {
            try {
              handler.postMessage({token, documentURL: location.href, event: 'partial', url,
                relatedURL: item.playlist, title: '', source: item.source, mime: item.mime});
            } catch (_) {}
          }
          function observePlaylistText(text, playlist, source, mime) {
            if (!encoder || typeof text !== 'string' || text.length > metadataByteLimit ||
                encoder.encode(text).length > metadataByteLimit) return;
            const lines = text.split(/\r?\n/).map(line => line.trim());
            if (lines.length > 10000 || lines[0] !== '#EXTM3U') return;
            // A master URI names another playlist, not a partial video. Only
            // explicit EXT-X-MAP and EXTINF media references provide evidence.
            const master = lines.some(line => /^#EXT-X-(?:STREAM-INF|I-FRAME-STREAM-INF):/.test(line));
            const referenced = new Set();
            let segment = false, byteRange = false;
            try {
              const remember = raw => {
                if (!raw || raw.length > 8192 || /[\u0000-\u001f\u007f]/.test(raw) || raw.includes('{$')) throw Error('invalid URI');
                const url = new URL(raw, playlist);
                if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.href.length > 8192) throw Error('invalid URI');
                referenced.add(url.href);
                if (referenced.size > 512) throw Error('too many references');
              };
              for (const line of lines) {
                if (line.startsWith('#EXT-X-MAP:')) {
                  const match = /(?:[:,])\s*URI="([^"]+)"/.exec(line);
                  if (!match) return;
                  // A byte range may point into a complete MP4 file. Evidence
                  // about one interval must not suppress its whole resource.
                  if (!/(?:[:,])\s*BYTERANGE=/.test(line)) remember(match[1]);
                } else if (line.startsWith('#EXTINF:')) {
                  segment = !master; byteRange = false;
                } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
                  byteRange = true;
                } else if (line && !line.startsWith('#')) {
                  if (segment && !byteRange) remember(line);
                  segment = false; byteRange = false;
                }
              }
            } catch (_) { return; }
            const item = {playlist, source, mime: (mime || '').slice(0, 200)};
            for (const url of referenced) {
              if (partialResources.size >= 512 && !partialResources.has(url)) continue;
              if (partialResources.has(url)) continue;
              partialResources.set(url, item);
              const previous = observed.get(url);
              if (previous && !['video', 'source'].includes(previous.source)) observed.delete(url);
              for (const [key, alternative] of alternatives) {
                if (alternative.url === url) alternatives.delete(key);
              }
              sendPartial(url, item);
            }
          }
          function observeMetadataText(text) {
            if (!encoder || typeof text !== 'string' || text.length > metadataByteLimit ||
                encoder.encode(text).length > metadataByteLimit) return;
            try { inspectMetadata(JSON.parse(text)); } catch (_) {}
          }
          async function observeFetchMetadata(response, generation) {
            const mime = response.headers.get('Content-Type');
            const lengthHeader = response.headers.get('Content-Length');
            const playlist = playlistResponse(response.url, mime, lengthHeader);
            if (!encoder || metadataReaders >= 2 || hasProtected || !response.ok || response.bodyUsed ||
                (!playlist && !metadataResponse(response.url, mime, lengthHeader))) return;
            metadataReaders++;
            let reader, timeout, stopped = false;
            const stop = () => {
              stopped = true;
              if (reader) {
                try { Promise.resolve(reader.cancel()).catch(() => {}); } catch (_) {}
              }
            };
            try {
              const clone = response.clone();
              if (!clone.body || typeof clone.body.getReader !== 'function') return;
              reader = clone.body.getReader();
              timeout = setTimeout(stop, 8000);
              const chunks = [];
              let length = 0;
              while (!stopped) {
                const next = await reader.read();
                if (stopped || generation !== historyGeneration) { stop(); return; }
                if (next.done) break;
                length += next.value.byteLength;
                if (length > metadataByteLimit || chunks.length >= 4096) { stop(); return; }
                chunks.push(next.value);
              }
              const joined = new Uint8Array(length);
              let offset = 0;
              for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.byteLength; }
              if (generation === historyGeneration) {
                const text = new TextDecoder('utf-8', {fatal: true}).decode(joined);
                if (playlist) observePlaylistText(text, response.url, 'fetch', mime);
                else observeMetadataText(text);
              }
            } catch (_) { stop(); }
            finally {
              clearTimeout(timeout);
              if (reader) { try { reader.releaseLock(); } catch (_) {} }
              metadataReaders--;
            }
          }
          function observeXHRMetadata(xhr) {
            if (hasProtected || xhr.status < 200 || xhr.status >= 300) return;
            const mime = xhr.getResponseHeader('Content-Type');
            if (playlistResponse(xhr.responseURL, mime, xhr.getResponseHeader('Content-Length'))) {
              if (!xhr.responseType || xhr.responseType === 'text') observePlaylistText(xhr.responseText, xhr.responseURL, 'xhr', mime);
              else if (xhr.responseType === 'arraybuffer' && xhr.response instanceof ArrayBuffer && xhr.response.byteLength <= metadataByteLimit) {
                observePlaylistText(new TextDecoder('utf-8', {fatal: true}).decode(xhr.response), xhr.responseURL, 'xhr', mime);
              }
              return;
            }
            if (!metadataResponse(xhr.responseURL, mime, xhr.getResponseHeader('Content-Length'))) return;
            if (xhr.responseType === 'json') inspectMetadata(xhr.response);
            else if (!xhr.responseType || xhr.responseType === 'text') observeMetadataText(xhr.responseText);
          }
          function selectedSource(video) {
            const sources = Array.from(video.querySelectorAll('source')).slice(0, 30);
            // currentSrc is the source WebKit actually chose, including a fresh
            // signed URL. Never substitute a network request from another video.
            const current = video.currentSrc || video.getAttribute('src') || '';
            if (current) {
              const selected = sources.find(item => item.src === current);
              const known = observed.get(current);
              return {url: current, source: 'video',
                mime: (selected && selected.type) || video.getAttribute('type') || (known && known.mime) || ''};
            }
            const selected = sources.find(item => item.getAttribute('src') &&
              (!item.type || video.canPlayType(item.type)));
            return selected ? {url: selected.src, source: 'source', mime: selected.type || ''} : null;
          }
          function requestDownload(video) {
            const title = videoTitle(video);
            if (protectedVideos.has(video) || video.mediaKeys) {
              markProtected(video);
              post('download-protected', '', 'video', '', title); return;
            }
            const selected = selectedSource(video);
            if (selected && selected.url.startsWith('blob:')) {
              post('download-mse', '', 'video', '', title); return;
            }
            try {
              if (!selected || !selected.url || selected.url.length > 8192) throw new Error();
              const url = new URL(selected.url, document.baseURI);
              if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
                  /\.(m4s|cmfv|cmfa|ts)(?:$|[?#])/i.test(url.href)) throw new Error();
              // Explicit clicks have their own short debounce and are not lost
              // when the background discovery budget or deduplication is full.
              post('download', url.href, selected.source, selected.mime, title);
            } catch (_) { post('download-unavailable', '', 'video', '', title); }
          }
          function controlAnchor(video, context) {
            let anchor = video;
            let parent = video.parentElement;
            // Player wrappers often absolutely position the video and clip their
            // fixed-height contents. Put the button after that wrapper, keeping
            // the original video and the site's controls untouched.
            for (let depth = 0; parent && depth < 10; depth++, parent = parent.parentElement) {
              if (parent === document.body || parent === document.documentElement || parent.tagName === 'MAIN') break;
              // Never move a video's action outside a shared multi-video group.
              if (boundedVideoCount(parent, context) !== 1) break;
              const style = getComputedStyle(parent);
              const clips = ['hidden', 'clip'].includes(style.overflowX) ||
                ['hidden', 'clip'].includes(style.overflowY) || style.clipPath !== 'none' ||
                /(?:^|\s)(?:paint|strict|content)(?:\s|$)/.test(style.contain);
              const parentOutOfFlow = ['absolute', 'fixed'].includes(style.position);
              const insertionParent = anchor.parentElement === parent;
              const insertionNeedsSpace = insertionParent &&
                (['absolute', 'fixed'].includes(getComputedStyle(anchor).position) ||
                 ['flex', 'inline-flex', 'grid', 'inline-grid'].includes(style.display));
              if (clips || parentOutOfFlow || insertionNeedsSpace) anchor = parent;
            }
            return anchor;
          }
          function placeControl(video, context) {
            if (!controlsOnly) return;
            if (!video.isConnected || !video.parentElement || !['http:', 'https:'].includes(location.protocol)) return;
            let control = controls.get(video);
            if (!control) {
              const host = document.createElement('span');
              host.setAttribute('data-vyu-download', '');
              controlHosts.add(host);
              // Normal-flow placement gives this control its own space.
              host.style.cssText = 'all:initial!important;display:block!important;position:relative!important;' +
                'box-sizing:border-box!important;width:max-content!important;max-width:100%!important;' +
                'height:auto!important;margin:8px 0!important;padding:0!important;float:none!important;';
              const shadow = host.attachShadow({mode: 'closed'});
              const button = document.createElement('button');
              button.type = 'button';
              button.textContent = '下载此视频';
              button.setAttribute('aria-label', '下载此视频');
              button.setAttribute('data-vyu-download', '');
              button.style.cssText = 'appearance:none;display:inline-flex;align-items:center;justify-content:center;' +
                'min-height:40px;box-sizing:border-box;border:1px solid #cad4ee;border-radius:10px;' +
                'background:#eef3ff;color:#183b89;padding:8px 14px;font:600 14px/20px -apple-system,sans-serif;' +
                'cursor:pointer;touch-action:manipulation;';
              control = {host, lastClick: -Infinity};
              button.addEventListener('click', event => {
                if (!event.isTrusted || !video.isConnected) return;
                event.preventDefault(); event.stopPropagation();
                const now = performance.now();
                if (now - control.lastClick < 600) return;
                control.lastClick = now;
                requestDownload(video);
              });
              shadow.appendChild(button);
              controls.set(video, control);
              if (sizeObserver) sizeObserver.observe(video);
            }
            const visible = getComputedStyle(video).visibility !== 'hidden' &&
              Array.from(video.getClientRects()).some(rect => rect.width > 8 && rect.height > 8);
            control.host.style.setProperty('display', visible ? 'block' : 'none', 'important');
            const anchor = controlAnchor(video, context);
            if (anchor.nextSibling !== control.host) anchor.parentElement.insertBefore(control.host, anchor.nextSibling);
          }
          function inspect(video, context = titleContext()) {
            if (!video.isConnected) return;
            if (video.mediaKeys) markProtected(video);
            if (controlsOnly) {
              // Only the isolated world owns the closed-shadow action and its
              // trusted click. Page-world discovery cannot authorize a transfer.
              if (!attached.has(video)) {
                attached.add(video);
                for (const event of ['loadedmetadata', 'loadstart', 'play', 'playing', 'emptied']) {
                  video.addEventListener(event, () => inspect(video), {passive: true});
                }
                video.addEventListener('encrypted', () => markProtected(video), {passive: true});
              }
              placeControl(video, context);
              return;
            }
            const title = videoTitle(video, context);
            observe(video.currentSrc || video.src, 'video', video.getAttribute('type') || '', title);
            const sources = Array.from(video.querySelectorAll('source')).slice(0, 30);
            for (const source of sources) {
              observe(source.src, 'source', source.type || '', title);
            }
            if (!protectedVideos.has(video) && !video.mediaKeys) {
              const playlists = [], files = [];
              const currentPlaylist = alternativeURL(video.currentSrc || video.src, 'm3u8');
              if (currentPlaylist) playlists.push(currentPlaylist);
              for (const source of sources) {
                const mime = (source.type || '').toLowerCase().split(';')[0].trim();
                const playlist = alternativeURL(source.src, 'm3u8');
                if (playlist && !playlists.includes(playlist)) playlists.push(playlist);
                const file = alternativeURL(source.src, 'mp4');
                if (file && (mime === 'video/mp4' || (!mime && /\.mp4(?:$|[?#])/i.test(file))) && !files.includes(file)) files.push(file);
              }
              rememberAlternatives(playlists, files, title);
            }
            if (!attached.has(video)) {
              attached.add(video);
              for (const event of ['loadedmetadata', 'loadstart', 'play', 'playing', 'webkitbeginfullscreen', 'durationchange', 'emptied']) {
                video.addEventListener(event, () => inspect(video), {passive: true});
              }
              video.addEventListener('encrypted', () => {
                markProtected(video);
              }, {passive: true});
            }
            placeControl(video, context);
          }
          function scan() {
            pending = false;
            const videos = Array.prototype.slice.call(document.getElementsByTagName('video'), 0, 80);
            const context = titleContext();
            const live = new Set(videos);
            for (const [video, control] of controls) {
              if (!live.has(video)) {
                control.host.remove(); controls.delete(video);
                if (sizeObserver) sizeObserver.unobserve(video);
              }
            }
            for (const video of videos) inspect(video, context);
          }
          function scheduleScan() {
            if (!pending) { pending = true; setTimeout(scan, 180); }
          }
          function resources() {
            if (controlsOnly) return;
            try {
              for (const entry of performance.getEntriesByType('resource').slice(-500)) {
                if (entry.startTime >= resourceCutoff && !(entry.responseStatus > 0 && (entry.responseStatus < 200 || entry.responseStatus >= 300))) observe(entry.name, 'performance', '');
              }
            } catch (_) {}
          }
          function refresh(resetHistory = false) {
            if (resetHistory === true) {
              historyGeneration++;
              resourceCutoff = performance.now();
              observed.clear(); alternatives.clear(); alternativeGroups.clear(); partialResources.clear();
              // Keep encrypted/media-source signals: rescanning cannot remove DRM.
            }
            seen.clear(); emitted = 0;
            if (metadataTimer !== null) clearTimeout(metadataTimer);
            metadataTimer = null; metadataUpdates = 0;
            publishedMetadata.clear(); pendingMetadata.clear();
            if (hasProtected) post('protected', '', 'encrypted', '');
            for (const [url, item] of partialResources) sendPartial(url, item);
            // Retain MIME-only network discoveries that happened before native commit.
            for (const [url, item] of observed) send('candidate', url, item.source, item.mime, item.title);
            for (const item of alternatives.values()) sendAlternative(item);
            scan(); resources();
            if (hasBlob) send('mse', '', 'video', '');
            for (const frame of Array.from(document.querySelectorAll('iframe')).slice(0, 80)) {
              try { frame.contentWindow.postMessage({vyuScan: token, resetHistory: resetHistory === true}, '*'); } catch (_) {}
            }
          }
          // The page world is necessary to observe calls made by the site's player.
          // The original fetch result is returned without reading or replacing its body.
          if (!controlsOnly) {
          try {
            const original = window.fetch;
            if (typeof original === 'function') window.fetch = function(...args) {
              const generation = historyGeneration;
              const result = Reflect.apply(original, this, args);
              result.then(response => {
                if (generation !== historyGeneration || !response.ok) return;
                try {
                  observe(response.url, 'fetch', response.headers.get('Content-Type') || '');
                  observeFetchMetadata(response, generation).catch(() => {});
                } catch (_) {}
              }, () => {});
              return result;
            };
          } catch (_) {}
          try {
            const original = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.send = function(...args) {
              const generation = historyGeneration;
              this.addEventListener('loadend', () => {
                if (generation !== historyGeneration || this.status < 200 || this.status >= 300) return;
                try {
                  observe(this.responseURL, 'xhr', this.getResponseHeader('Content-Type') || '');
                  observeXHRMetadata(this);
                } catch (_) {}
              }, {once: true});
              return Reflect.apply(original, this, args);
            };
          } catch (_) {}
          try {
            const observer = new PerformanceObserver(list => {
              for (const entry of list.getEntries()) {
                if (entry.startTime >= resourceCutoff && !(entry.responseStatus > 0 && (entry.responseStatus < 200 || entry.responseStatus >= 300))) observe(entry.name, 'performance', '');
              }
            });
            observer.observe({type: 'resource', buffered: true});
          } catch (_) {}
          }
          try {
            new MutationObserver(changes => {
              // Site layout changes can introduce clipping without changing the
              // video's dimensions. Ignore our own style writes to avoid a loop.
              if (changes.some(change => change.type !== 'attributes' || !controlHosts.has(change.target))) scheduleScan();
            }).observe(document, {
              subtree: true, childList: true, characterData: true, attributes: true,
              attributeFilter: ['src', 'type', 'class', 'style', 'hidden', 'title', 'aria-label', 'aria-labelledby', 'aria-describedby']
            });
          } catch (_) {}
          window.addEventListener('message', event => {
            // A restored back/forward document keeps its JS state. Only the current
            // parent passes the new navigation epoch down through its live frame tree.
            if (window.parent !== window && event.source === window.parent && event.data &&
                typeof event.data.vyuScan === 'string' && /^[0-9A-F-]{36}$/i.test(event.data.vyuScan)) {
              token = event.data.vyuScan; refresh(event.data.resetHistory === true);
            }
          });
          window.addEventListener('pageshow', refresh, {passive: true});
          window.addEventListener('resize', scheduleScan, {passive: true});
          document.addEventListener('DOMContentLoaded', refresh, {once: true});
          window.__vyuRescan = refresh;
          window.__vyuSetNavigationToken = (next, resetHistory = false) => {
            if (typeof next === 'string' && /^[0-9A-F-]{36}$/i.test(next)) { token = next; refresh(resetHistory === true); }
          };
          scan();
        })();
        """#
    }
}
