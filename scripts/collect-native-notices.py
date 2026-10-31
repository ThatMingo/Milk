#!/usr/bin/env python3
"""Collect upstream native runtime copyright/license texts (build-time only)."""
import concurrent.futures,pathlib,urllib.request
root=pathlib.Path(__file__).resolve().parent.parent
sources={
'BoringSSL':'https://raw.githubusercontent.com/google/boringssl/main/LICENSE',
'Brotli':'https://raw.githubusercontent.com/google/brotli/master/LICENSE',
'libarchive':'https://raw.githubusercontent.com/libarchive/libarchive/master/COPYING',
'lol-html':'https://raw.githubusercontent.com/cloudflare/lol-html/master/LICENSE',
'ls-hpack':'https://raw.githubusercontent.com/litespeedtech/ls-hpack/master/LICENSE',
'ls-qpack':'https://raw.githubusercontent.com/litespeedtech/ls-qpack/master/LICENSE',
'lsquic':'https://raw.githubusercontent.com/litespeedtech/lsquic/master/LICENSE',
'lsquic-Chromium':'https://raw.githubusercontent.com/litespeedtech/lsquic/master/LICENSE.chrome',
'mimalloc':'https://raw.githubusercontent.com/microsoft/mimalloc/master/LICENSE',
'picohttpparser':'https://raw.githubusercontent.com/h2o/picohttpparser/master/picohttpparser.h',
'zstd':'https://raw.githubusercontent.com/facebook/zstd/dev/LICENSE',
'simdutf':'https://raw.githubusercontent.com/simdutf/simdutf/master/LICENSE-APACHE',
'uSockets':'https://raw.githubusercontent.com/uNetworking/uSockets/master/LICENSE',
'zlib-ng':'https://raw.githubusercontent.com/zlib-ng/zlib-ng/develop/LICENSE.md',
'c-ares':'https://raw.githubusercontent.com/c-ares/c-ares/main/LICENSE.md',
'ICU':'https://raw.githubusercontent.com/unicode-org/icu/main/LICENSE',
'libbase64':'https://raw.githubusercontent.com/aklomp/base64/master/LICENSE',
'libdeflate':'https://raw.githubusercontent.com/ebiggers/libdeflate/master/COPYING',
'libjpeg-turbo':'https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/LICENSE.md',
'libjpeg-turbo-README':'https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/README.ijg',
'libspng':'https://raw.githubusercontent.com/randy408/libspng/master/LICENSE',
'libwebp':'https://raw.githubusercontent.com/webmproject/libwebp/main/COPYING',
'Highway':'https://raw.githubusercontent.com/google/highway/master/LICENSE',
'uucode':'https://raw.githubusercontent.com/oven-sh/bun/bun-v1.3.14/src/unicode/uucode_lib/LICENSE.md',
'uWebSockets':'https://raw.githubusercontent.com/oven-sh/bun/bun-v1.3.14/packages/bun-uws/LICENSE',
'Node':'https://raw.githubusercontent.com/nodejs/node/v22.19.0/LICENSE',
'esbuild':'https://raw.githubusercontent.com/evanw/esbuild/main/LICENSE.md',
'JavaScriptCore-LGPL':'https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/COPYING.LIB',
'WebKit-BSD':'https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/runtime/JSCell.h',
'QuickJS':'https://raw.githubusercontent.com/bellard/quickjs/master/LICENSE',
'LLVM':'https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-19.1.0/libcxxabi/LICENSE.TXT',
}
def read(item):
 name,url=item
 cache=pathlib.Path('/tmp/milk-native-notices'); cache.mkdir(exist_ok=True)
 path=cache/name
 if path.exists(): data=path.read_text()
 else:
  try:
   with urllib.request.urlopen(url,timeout=45) as r: data=r.read().decode('utf-8','replace')
   path.write_text(data)
  except Exception as error: raise RuntimeError(name+' '+url+' '+str(error))
 return '='*78+'\n'+name+'\nSource: '+url+'\n\n'+data
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool: values=list(pool.map(read,sources.items()))
(root/'ThirdPartyNotices/Runtime-Libraries.txt').write_text('Upstream copyright and license texts for native libraries identified by Bun 1.3.14 and the Pi runtime. See Bun-LICENSE.md for linkage and relinking guidance. Platform-specific extras are included conservatively.\n\n'+'\n\n'.join(values))
print('Collected',len(values),'native library notices')
