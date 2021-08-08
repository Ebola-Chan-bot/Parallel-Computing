埃博拉酱的并行计算工具包，提供一系列MATLAB内置函数所欠缺，但却常用的并行计算功能

本项目的发布版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)规范。开发者认为这是一个优秀的规范，并向每一位开发者推荐遵守此规范。
# 目录
本包中所有函数均在ParallelComputing命名空间下，使用前需import。使用命名空间是一个好习惯，可以有效防止命名冲突，避免编码时不必要的代码提示干扰。
- [+Cluster](#Cluster)
	- [SetParpool](#SetParpool)
# +Cluster
## SetParpool
将当前并行池设定指定的工作进程数目

MATLAB内置的parpool无法覆盖已有并行池，也不检查当前并行池尺寸是否恰好和设置一致，十分蹩脚。本函数一键解决问题，只需输入你想要的并行池尺寸，就能将当前并行池要么恰好尺寸一致而保留，要么尺寸不一致而关闭重启

输入参数：NumWorkers(1,1)，理想的并行池尺寸

返回值：Pool(1,1)parallel.ProcessPool，生成或当前的并行池，其NumWorkers属性与输入值一致