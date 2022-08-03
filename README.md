埃博拉酱的并行计算工具箱，提供一系列实用的并行计算辅助功能

本项目的发布版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)规范。开发者认为这是一个优秀的规范，并向每一位开发者推荐遵守此规范。
# 目录
本包中所有函数均在ParallelComputing命名空间下，使用前需import。使用命名空间是一个好习惯，可以有效防止命名冲突，避免编码时不必要的代码提示干扰。
```MATLAB
import ParallelComputing.*
```
每个代码文件内都有详细文档，此处只列举公开接口简介。详情可用doc命令查询。
类
```MATLAB
classdef BlockRWStream<handle
	%为无法一次性全部读入内存的大文件，提供单线程读写、多线程计算的解决方案
	%% 本地
	properties(SetAccess=immutable,Transient)
		%输入的文件列表，依次作为GetRWer的参数以获取读写器。
		RWObjects
		%文件个数
		NumObjects
		%获取读写器的函数句柄，通常是读写器的构造函数
		GetRWer
	end
	properties(SetAccess=private,Transient)
		%已经读完的文件个数
		ObjectsRead
		%当前文件已经读完的数据片个数
		PiecesRead
		%已经读完的数据块总数
		BlocksRead
		%维护每个数据块的信息表
		BlockTable
		%维护每个文件的信息表
		ObjectTable
	end
	methods(Access=protected)
		function NextObject(obj)
			%打开新的文件以供读取。此方法只有在BlockRWStream刚刚构建完毕，以及上一个文件读取完毕后才被内部调用。但需要检查是否所有文件已经读完。
		end
	end
	methods
		function obj = BlockRWStream(RWObjects,GetRWer)
			%构造方法。需要提供文件列表和获取读写器的函数句柄。
		end
		function [Data,BlockIndex]=LocalReadBlock(obj,ReadSize,ReturnQueue)
			%在单进程环境下，读入一个数据块。
		end
		function LocalWriteBlock(obj,Data,BlockIndex)
			%在单进程环境下，写出一个数据块。
		end
		function [CollectData,Metadata]=CollectReturn(obj)
			%所有计算线程结束后，由主线程调用此方法，收集返回的计算结果。
		end
		function [CollectData,Metadata]=SpmdRun(obj,BlockProcess,ConstantArgument,options)
			%BlockRWStream的招牌方法，用几个简单的参数实现单线程I/O多线程计算框架
		end
	end
	%% 远程
	methods
		function IPollable=RemoteReadAsync(obj,ReadSize)
			%在计算线程上，向I/O线程异步请求读入一个数据块。异步请求不会等待，而是先返回继续执行别的代码，等需要数据时再提取结果。
		end
		function [Data,Index]=RemoteReadBlock(obj,ReadSize)
			%在计算线程上，向I/O线程请求读入一个数据块
		end
		function RemoteWriteBlock(obj,Data,Index)
			%在计算线程上，向I/O线程请求写出一个数据块
		end
	end
end
classdef(Abstract)IBlockRWer<handle
	%为BlockRWStream所调用的读写器必须实现的抽象接口类
	properties(SetAccess=immutable,Abstract)
		%必须实现的抽象属性，指示每个数据片的字节数。BlockRWStream将根据此属性决定一次要读取多少片。
		PieceSize double
		%必须实现的抽象属性，指示文件中有多少个数据片。BlockRWStream将根据此属性判断是否已读取完该文件。
		NumPieces double
		%必须实现的抽象属性，专属于该文件的元数据信息。BlockRWStream将在打开每个文件时收集该元数据。如果文件没有元数据，可以不设置此属性的值。
		Metadata
	end
	methods(Abstract)
		%必须实现的抽象成员方法，用于读取指定的数据块。
		Data=Read(obj,Start,End)
	end
	methods
		function Data=Write(~,Data,~,~)
			%可选重写的成员方法，用于写出数据块
		end
	end
end
classdef RemoteFunctionHandle<handle
	%远程调用句柄。无论在哪个线程上调用，都会在创建对象的线程上执行
	%% 服务端
	methods
		function obj = RemoteFunctionHandle(FunctionHandle)
			%构造函数接受一个function_handle对象作为参数。该函数句柄将使用创建线程的资源执行。
		end
	end
	%% 客户端
	methods
		function varargout=Invoke(obj,varargin)
			%向创建线程请求执行函数，并等待返回值。如果没有返回值，该调用将不会等待执行完成。
		end
		function Poller=InvokeAsync(obj,NArgOut,Arguments)
			%异步调用请求。请求不会等待执行完成，而是立刻返回一个parallel.pool.PollableDataQueue，可以等后续实际需要改返回值时再等待。
		end
	end
end
```
函数
```MATLAB
%修复含有非ASCII字符的主机名的主机不能启动并行池的问题
function NonAsciiHostnameParpoolFix
%内置parpool函数的增强版，可选保留当前配置不变
function Pool = ParPool(options)
```