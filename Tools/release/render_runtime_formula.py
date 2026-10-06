#!/usr/bin/env python3
# Copyright 2026 container-compose project authors. SPDX-License-Identifier: Apache-2.0
"""Substitute only the actual frozen runtime-notices asset digest."""
import argparse
import hashlib
import os
from pathlib import Path
import re

TEMPLATE_SHA256='223b46432e078b10bf7fec893c1a07dcdd76baa3e7d2cd71d377bb0836645cdd'
PLACEHOLDER='@RUNTIME_NOTICES_SHA256@'

def render(data, notices_sha256):
    if hashlib.sha256(data).hexdigest()!=TEMPLATE_SHA256:
        raise ValueError('Frozen formula template differs')
    if not re.fullmatch(r'[0-9a-f]{64}',notices_sha256) or notices_sha256=='0'*64:
        raise ValueError('Actual non-placeholder notices digest is required')
    text=data.decode('utf-8')
    if text.count(PLACEHOLDER)!=1:
        raise ValueError('Exactly one notices placeholder is required')
    return text.replace(PLACEHOLDER,notices_sha256).encode('utf-8')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notices-sha256',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    template=Path(__file__).with_name('container-bazel.rb.in')
    if template.is_symlink():raise ValueError('Template is aliased')
    data=render(template.read_bytes(),args.notices_sha256)
    output=args.output
    if not output.is_absolute() or output.parent.resolve()!=output.parent or output.parent.stat().st_uid!=os.getuid():
        raise ValueError('Output parent is not canonical and owned')
    fd=os.open(output,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream:
        stream.write(data);stream.flush();os.fsync(stream.fileno())
    print(hashlib.sha256(data).hexdigest())

if __name__=='__main__':main()
