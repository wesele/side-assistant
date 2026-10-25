#!/usr/bin/env python
"""Entry point:  python run.py  [--mock]"""

import sys

from nanotest.app import main

if __name__ == "__main__":
    sys.exit(main())
