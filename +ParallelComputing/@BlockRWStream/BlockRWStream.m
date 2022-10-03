classdef BlockRWStream<handle
	%为无法一次性全部读入内存的大文件，提供单线程读写、多线程计算的解决方案
	%处理大量数据时，经常遇到单个数据文件过大，无法一次性全部读入内存再处理的问题。此时只能先读入一个小数据块，计算处理后，输出结果，释放内存，再读入下一个。在单线程环境下，这是唯一的解决方案。
	%但在多线程环境下，我们往往发现，尽管中间计算过程受益于多线程得到了加速，但输入和输出的I/O过程，只能单线程执行：磁盘、网络等I/O设备并不会被多线程加速。即使在代码中指定为并行I/O，硬件上也不能真正做到并行，而仅仅是在多个线程之间不断切换实现的"伪
	% 并行"，更不用说这种切换还会产生额外的开销，总体性能还不如单线程。
	%因此我们认为，在多线程环境下的最优方案，是单线程读写、多线程计算。即设置一个服务线程，专门负责I/O等单线程操作，然后将数据分发到多个工作线程执行计算，计算结果再归并到服务线程执行写出操作。
	%MATLAB恰好提供了一个这样的线程模型，即主线程-并行计算模型。MATLAB的界面和一般的代码、命令行任务都在主线程中执行，但可以在代码中引入并行命令，如 spmd parfor parfeval 等（依赖 Parallel Computing Toolbox），在并行线程上执行代码。
	%BlockRWStream在此基础上建立了一个框架，以支持在主线程上执行对文件的分块I/O操作，在并行线程上执行计算。其中复杂的线程同步、数据分发和收集问题，都被封装起来，对用户透明。用户只需要关心数据的具体读写操作和处理过程。
	%请注意，并行线程并非多多益善，而是存在一个最优数目，为数据计算时间与I/O时间之比，向上取整。例如，读入一个数据块需要1min，处理这些数据需要5min，写出计算结果又需要1min，那么最优的线程配置方案就是ceil(5/(1+1))=3个计算线程，加上1个I/O主线程，共
	% 4个线程。过多的计算线程只会长期处于等待主线程I/O的状态，并不能缩短总的工作时间，反而占用额外的内存。特别地，如果计算时间比I/O时间还要短，那么1个I/O线程+1个计算线程共2个线程的方案就已经达到最优。具体的方案因硬件和任务而异，需要用户手动设置，
	% BlockRWStream只会按照当前设置安排并行。在不知道具体的计算时间与I/O时间之比时，可以通过试验测定。线程数达到最优的判定标准是，在保证I/O线程稳定处于满负荷工作状态条件下，并行线程数尽可能少。用户可以使用ParallelComputing.SetParpool轻松设置并
	% 行线程个数，更复杂的设置则需参考parpool文档。
	%
	%下面给出一个示例。该示例执行的任务是，读入一批庞大的视频文件，将每个视频的所有帧叠加取平均，得到平均帧图，每个视频输出一张图。
	%第一步，实现ParallelComputing.IBlockRWer抽象接口类，定义视频读入过程。此代码在ParallelComputing.IBlockRWer的文档中展示，此处不再赘述。
	%第二步，定义BatchVideoMean函数，利用BlockRWStream实现视频批量平均图操作：
	%```
	%function BatchVideoMean(VideoPaths)
	% %BlockVideoReader是实现了ParallelComputing.IBlockRWer的具体类。将它的构造函数句柄交给BlockRWStream构造函数，得到的对象执行SpmdRun方法，对每个数据块返回其全帧总和和帧数。数据块可以在GPU上执行计算，返回2个元胞。计算过程将占用2倍于数据块大
	% 小的内存。
	%CollectData=ParallelComputing.BlockRWStream(VideoPaths,@BlockVideoReader).SpmdRun(@(Data){sum(Data,4),size(Data,4)},NArgOut=1,NumGpuArguments=1,RuntimeCost=2);
	% %返回的CollectData包含了所有文件所有数据块的全帧总和和帧数。
	%[Directories,Filenames]=fileparts(VideoPaths);
	%OutputPaths=fullfile(Directories,Filenames+".平均.png");
	% %将在每个视频文件的同目录下生成一个平均帧PNG图像。
	%for V=1:numel(CollectData)
	%	Data=vertcat(CollectData{V}{:});
	%	Data=vertcat(Data{:});
	%	%将每个文件的数据块归并，计算全帧平均，写出PNG图像。
	%	imwrite(uint8(sum(cat(4,Data{:,1}))/sum([Data{:,2}])),OutputPaths(V));
	%end
	%```
	%此示例中，数据块的计算操作实际上只有一个求和和求尺寸，非常快，一般不会比读入时间更长，所以只需1个计算线程+1个I/O线程就足够了。调用此函数BatchVideoMean之前可以使用ParallelComputing.SetParpool(1)以设置只使用1个计算线程。
	%
	%BlockRWStream的所有方法均支持子类继承重写。您可以在理解其工作原理的基础上按需更改其行为。在ParallelComputing.BlockRWStream.NextObject文档中提供了一个示例，该示例重写NewObject函数，以实现每次读取新文件时输出进度信息。
	%本类的属性一般作调试信息用，监视进度和状态，不应手动修改。
	%多数情况下，您只需实现IBlockRWer、构造BlockRWStream对象、调用ParallelComputing.BlockRWStream.SpmdRun方法即可完成工作流。如果您需要更自定义地控制工作流，可以自行建立并行框架，然后调用BlockRWStream下的 Local/Remote Read/Write Block 方
	% 法，进行自定义的本地/远程读写操作。SpmdRun本质上也是通过调用这些方法实现的。SpmdRun方法的文档中展示了工作流的细节，建议参考。
	%此类对象的使用是一次性的。一旦所有文件读取完毕，对象就会报废，无法重复使用，必须新建。
	%See also ParallelComputing.SetParpool parpool ParallelComputing.IBlockRWer ParallelComputing.BlockRWStream.SpmdRun
	
	%% 通信
	properties(SetAccess=immutable,GetAccess=private,Hidden)
		RequestQueue parallel.pool.DataQueue
	end
	%% 本地
% 	properties(SetAccess=immutable,GetAccess=private,Transient)
% 		ReadMutex parallel.pool.PollableDataQueue
% 		WriteMutex parallel.pool.PollableDataQueue
% 	end
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
		ObjectsRead=0
		%当前文件已经读完的数据片个数
		PiecesRead
		%已经读完的数据块总数
		BlocksRead=0
		%维护每个数据块的信息表
		BlockTable=table('Size',[0,4],'VariableTypes',["uint16","uint16","uint16","cell"],'VariableNames',["ObjectIndex","StartPiece","EndPiece","ReturnData"])
		%维护每个文件的信息表
		ObjectTable
	end
	methods(Access=protected)
		function NextObject(obj)
			%打开新的文件以供读取。此方法只有在BlockRWStream刚刚构建完毕，以及上一个文件读取完毕后才被内部调用。但需要检查是否所有文件已经读完。
			%此方法没有输入输出，仅设置类内部各属性的状态。此方法标志着上一个文件读入完毕、下一个文件开始读入，因此可以重写它以输出进度信息。如下示例：
			%```
			%classdef ShowProgress<ParallelComputing.BlockRWStream
			%	methods(Access=protected)
			%		function NextObject(obj)
			%			%先调用基类，执行该方法必要的基本功能
			%			obj.NextObject@ParallelComputing.BlockRWStream;
			%			%然后输出进度
			%			Index=obj.ObjectsRead+1;
			%			fprintf('文件%u/%u：%s\n',Index,obj.NumObjects,obj.RWObjects(Index));
			%		end
			%	end
			%	methods
			%		function obj=ShowProgress(RWObjects,GetRWer)
			%			obj@ParallelComputing.BlockRWStream(RWObjects,GetRWer);
			%		end
			%	end
			%end
			%```
			Index=obj.ObjectsRead+1;
			if Index<=obj.NumObjects
				obj.PiecesRead=0;
				RWer=obj.GetRWer(obj.RWObjects(Index));
				obj.ObjectTable(Index,1:2)={{RWer.Metadata},{RWer}};
			end
		end
	end
	methods
		function obj = BlockRWStream(RWObjects,GetRWer)
			%构造方法。需要提供文件列表和获取读写器的函数句柄。
			%# 语法
			% obj=ParallelComputing.BlockRWStream(RWObjects,GetRWer);
			%# 输入参数
			% RWObjects(:,1)，文件列表。本质上是要交给GetRWer的参数，因此该参数具体内容由GetRWer决定。每次打开新文件，会将RWObjects的一个元素交给GetRWer以获取读写器。可以用元胞包含复杂参数，或者继承此类以实现更复杂的构造。
			% GetRWer，用于获取读写器的函数句柄。该句柄必须只接受一个标量参数，输出一个ParallelComputing.IBlockRWer对象。
			%See also ParallelComputing.IBlockRWer
			import parallel.pool.*
			obj.RWObjects=RWObjects;
			obj.NumObjects=numel(RWObjects);
			obj.GetRWer=GetRWer;
			obj.RequestQueue=DataQueue;
			obj.RequestQueue.afterEach(@(Request)obj.(Request{1})(Request{2:end}));
			obj.ObjectTable=table('Size',[obj.NumObjects,4],'VariableTypes',["cell","cell","uint16","uint16"],'VariableNames',["Metadata","RWer","BlocksRead","BlocksWritten"]);
			obj.NextObject;
% 			obj.ReadMutex=PollableDataQueue;
% 			obj.ReadMutex.send([]);
% 			obj.WriteMutex=PollableDataQueue;
% 			obj.WriteMutex.send([]);
		end
		function [Data,BlockIndex,ObjectIndex,ObjectData]=LocalReadBlock(obj,ReadSize,LastObjectIndex,ReturnQueue)
			%在单线程环境下，读入一个数据块。
			%此方法只能在构造该对象的进程上调用，多线程环境下则会发生争用，因此通常用于单线程环境，退化为读入-计算-写出的简单流程。
			%# 语法
			% [Data,BlockIndex]=obj.LocalReadBlock(ReadSize)
			%# 输入参数
			% ReadSize，建议读入的字节数。因为读入以数据片为最小单位，实际读入的字节数是数据片字节数的整倍，读入数据片的个数为建议字节数/数据片字节数，向下取整。
			%# 返回值
			% Data，读写器返回的数据块。实际读入操作由读写器实现，因此实际数据块大小不一定符合要求。BlockRWStream只对读写器提出建议，不检查其返回值。此外，如果所有文件已读完，将返回missing。
			% BlockIndex，数据块的唯一标识符。执行完计算后应将结果同此标识符一并返还给BlockRWStream.LocalWriteBlock，这样才能实现正确的结果收集和写出。如果所有文件已读完，将返回missing，可用ismissing是否应该结束计算线程。
			%See also ParallelComputing.BlockRWStream.LocalWriteBlock missing ismissing
			if obj.ObjectsRead<obj.NumObjects
				ObjectIndex=obj.ObjectsRead+1;
				Reader=obj.ObjectTable.RWer{ObjectIndex};
				EndPiece=min(obj.PiecesRead+floor(ReadSize/Reader.PieceSize),Reader.NumPieces);
				StartPiece=obj.PiecesRead+1;
				Data=Reader.Read(StartPiece,EndPiece);
				obj.BlocksRead=obj.BlocksRead+1;
				BlockIndex=obj.BlocksRead;
				if ObjectIndex>LastObjectIndex
					ObjectData=Reader.ProcessData;
				else
					ObjectData=missing;
				end
				if nargin>2
					ReturnQueue.send({Data,BlockIndex,ObjectIndex,ObjectData});
				end
				obj.ObjectTable.BlocksRead(ObjectIndex)=obj.ObjectTable.BlocksRead(ObjectIndex)+1;
				if height(obj.BlockTable)<obj.BlocksRead
					WarningState=warning;
					warning off
					obj.BlockTable.ObjectIndex(obj.BlocksRead*2)=0;
					warning(WarningState(1).state);
				end
				obj.BlockTable(obj.BlocksRead,1:3)={ObjectIndex,StartPiece,EndPiece};
				if EndPiece<Reader.NumPieces
					obj.PiecesRead=EndPiece;
				else
					obj.ObjectsRead=ObjectIndex;
					obj.NextObject;
				end
			else
				[Data,BlockIndex,ObjectIndex,ObjectData]=deal(missing);
				if nargin>2
					ReturnQueue.send({Data,BlockIndex,ObjectIndex,ObjectData});
				end
			end
		end
		function LocalWriteBlock(obj,Data,BlockIndex)
			%在单线程环境下，写出一个数据块。
			%此方法只能在构造该对象的进程上调用，多线程环境下则会发生争用，因此通常用于单线程环境，退化为读入-计算-写出的简单流程。
			%# 语法
			% obj.LocalWriteBlock(Data,BlockIndex)
			%# 输入参数
			% Data，数据块处理后的计算结果。可以用元胞数组包含多个复杂的结果。此参数将被直接交给读写器的Write方法。
			% BlockIndex，数据块的唯一标识符，从LocalWriteBlock获取，以确保读入数据块和返回计算结果一一对应。
			%See also ParallelComputing.BlockRWStream.LocalReadBlock
			ObjectIndex=obj.BlockTable.ObjectIndex(BlockIndex);
			Writer=obj.ObjectTable.RWer{ObjectIndex};
			obj.BlockTable.ReturnData{BlockIndex}=Writer.Write(Data,obj.BlockTable.StartPiece(BlockIndex),obj.BlockTable.EndPiece(BlockIndex));
			BlocksWritten=obj.ObjectTable.BlocksWritten(ObjectIndex)+1;
			if BlocksWritten==obj.ObjectTable.BlocksRead(ObjectIndex)&&obj.ObjectsRead>=ObjectIndex
				delete(Writer);
			end
			obj.ObjectTable.BlocksWritten(ObjectIndex)=BlocksWritten;
		end
		function [CollectData,Metadata]=CollectReturn(obj)
			%所有计算线程结束后，由主线程调用此方法，收集返回的计算结果。
			%# 返回值
			%CollectData，一个元胞列向量，每个元胞对应一个文件的计算结果。元胞内又是元胞列向量，每个元胞对应一个数据块的计算结果，即计算线程每次调用Local/Remote WriteBlock时提供的Data参数。如果使用SpmdRun，每个数据块的计算结果将是一个元胞行向量，对应计算函数的每个返回值。
			% 例如，如果返回m×1元胞列向量，说明输入的文件有m个；其中第a个元胞内是n×1元胞列向量，说明第a个文件被分成了n块读入；其中第b个元胞内是1×p元胞行向量，说明可能是用了SpmdRun且计算函数有p个返回值。
			%Metadata，每个文件的元数据，为每个读写器的Metadata属性值，排列在元胞列向量中。
			BlockIndex=1:obj.BlocksRead;
			CollectData=splitapply(@(RD){RD},obj.BlockTable.ReturnData(BlockIndex),obj.BlockTable.ObjectIndex(BlockIndex));
			Metadata=obj.ObjectTable.Metadata;
		end
	end
	%% 远程
	methods
		function IPollable=RemoteReadAsync(obj,ReadSize,LastObjectIndex)
			%在计算线程上，向I/O线程异步请求读入一个数据块。异步请求不会等待，而是先返回继续执行别的代码，等需要数据时再提取结果。
			%此方法可以在并行计算线程（parfor spmd parfeval 等）上调用，但会在I/O主线程上执行读入操作，然后将数据返回给计算线程。
			%# 语法
			% IPollable=obj.RemoteReadBlock(ReadSize)
			%# 示例
			%```
			% IPollable=obj.RemoteReadAsync(ReadSize);
			% DoOtherJob();
			% IPollable.poll(Inf);
			%```
			%# 输入参数
			% ReadSize，建议读入的字节数。因为读入以数据片为最小单位，实际读入的字节数是数据片字节数的整倍，读入数据片的个数为建议字节数/数据片字节数，向下取整。
			%# 返回值
			% IPollable(1,1)parallel.pool.PollableDataQueue，可等待的数据队列。需要数据时，调用其poll成员方法可以取得数据。poll将返回1×2元胞行向量，分别包含RemoteReadBlock的两个返回值。
			%See also ParallelComputing.BlockRWStream.RemoteReadBlock parallel.pool.PollableDataQueue.poll
			IPollable=parallel.pool.PollableDataQueue;
			obj.RequestQueue.send({'LocalReadBlock',ReadSize,LastObjectIndex,IPollable});
		end
		function [Data,BlockIndex,ObjectIndex,ObjectData]=RemoteReadBlock(obj,ReadSize,LastObjectIndex)
			%在计算线程上，向I/O线程请求读入一个数据块
			%此方法可以在并行计算线程（parfor spmd parfeval 等）上调用，但会在I/O主线程上执行读入操作，然后将数据返回给计算线程。
			%# 语法
			% [Data,BlockIndex]=obj.RemoteReadBlock(ReadSize)
			%# 输入参数
			% ReadSize，建议读入的字节数。因为读入以数据片为最小单位，实际读入的字节数是数据片字节数的整倍，读入数据片的个数为建议字节数/数据片字节数，向下取整。
			%# 返回值
			% Data，读写器返回的数据块。实际读入操作由读写器实现，因此实际数据块大小不一定符合要求。BlockRWStream只对读写器提出建议，不检查其返回值。此外，如果所有文件已读完，将返回missing。
			% BlockIndex，数据块的唯一标识符。执行完计算后应将结果同此标识符一并返还给BlockRWStream.RemoteWriteBlock，这样才能实现正确的结果收集和写出。如果所有文件已读完，将返回missing，可用ismissing是否应该结束计算线程。
			%See also ParallelComputing.BlockRWStream.RemoteWriteBlock missing ismissing
			varargout=obj.RemoteReadAsync(ReadSize,LastObjectIndex).poll(Inf);
			[Data,BlockIndex,ObjectIndex,ObjectData]=varargout{:};
		end
		function RemoteWriteBlock(obj,Data,Index)
			%在计算线程上，向I/O线程请求写出一个数据块
			%此方法可以在并行计算线程（parfor spmd parfeval 等）上调用，但会在I/O主线程上执行写出操作。计算线程在发出请求后不会等待操作完成，而是继续向下运行。
			%# 语法
			% obj.LocalWriteBlock(Data,BlockIndex)
			%# 输入参数
			% Data，数据块处理后的计算结果。可以用元胞数组包含多个复杂的结果。此参数将被直接交给读写器的Write方法。
			% BlockIndex，数据块的唯一标识符，从RemoteWriteBlock获取，以确保读入数据块和返回计算结果一一对应。
			%See also ParallelComputing.BlockRWStream.RemoteReadBlock
			obj.RequestQueue.send({'LocalWriteBlock',Data,Index});
		end
	end
end