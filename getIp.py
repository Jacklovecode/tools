# -*- coding: utf-8 -*-
"""
  该脚本用于清洗链接地址获取ip地址。
"""

import argparse
import re
import sys

ip_list=[]
def readPath(filepath):
    with open(filepath, "r",encoding='utf-8') as urls:
        for u in urls.readlines():
            # print(u)
            tmp_1 = re.findall(r'https?:\/\/.*/m', u)
            tmp_2 = re.findall(r'/[\w\-?*\.]+', str(tmp_1))
            result = str(tmp_2[0]).replace('/','')
            print(result)
            ip_list.append(result)

def writeIP(filepath):
    with open(filepath, "w",encoding='utf-8') as file:
        for ip in ip_list:
            file.write(str(ip)+"\n")

def parese_args():
    parse = argparse.ArgumentParser(epilog='\tExample: \r\npython '+sys.argv[0]+" -f example.txt"
                                    ,description="清洗链接转变为Ip地址")
    parse.add_argument("-f", "--file", help="包含需要清洗的链接的文件地址")
    return parse.parse_args()

if __name__ == '__main__':
    args = parese_args()
    if args.file != None:
        readPath(args.file)
        writeIP(args.file)
    else:
        sys.exit(0)