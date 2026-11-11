#!/usr/bin/env python3
import sys


def double(x):
    return x * 2


if __name__ == "__main__":
    print(double(int(sys.argv[1])))
