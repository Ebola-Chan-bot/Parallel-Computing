埃博拉酱的并行计算工具箱，提供一系列实用的并行计算辅助功能。依赖[埃博拉酱的MATLAB扩展](https://ww2.mathworks.cn/matlabcentral/fileexchange/96344-matlab-extension)
[![View 埃博拉酱 的 并行计算 工具箱 Parallel Computing on File Exchange](https://www.mathworks.com/matlabcentral/images/matlab-file-exchange.svg)](https://ww2.mathworks.cn/matlabcentral/fileexchange/99194-parallel-computing)
# 目录
本包中所有函数均在ParallelComputing命名空间下，使用前需import。
```MATLAB
import ParallelComputing.*
```
安装工具箱后可查看快速入门文档，可查看代码示例。每个代码文件内都有详细文档，此处只列举公开接口简介。详情可用doc命令查询。

类
```MATLAB
classdef BlockRWStream
	%为无法一次性全部读入内存的大文件，提供单线程读写、多线程计算的解决方案
end
classdef(Abstract)IBlockRWer
	%为BlockRWStream所调用的读写器必须实现的抽象接口类
end
classdef PoolWatchDog
	%并行池看门狗，可以自动删除长时间卡死的并行池
end
classdef RemoteFunctionHandle
	%远程调用句柄。无论在哪个线程上调用，都会在创建对象的线程上执行
end
```
函数
```MATLAB
%将指定的GPU分配到并行进程
function AssignGPUsToWorkers(UseGpu)
%修复含有非ASCII字符的主机名的主机不能启动并行池的问题
function NonAsciiHostnameParpoolFix(RestartMatlab)
%内置parpool函数的增强版，可选保留当前配置不变
function Pool = ParPool(varargin)
```
