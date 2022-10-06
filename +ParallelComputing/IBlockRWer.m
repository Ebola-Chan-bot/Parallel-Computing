classdef(Abstract)IBlockRWer<handle
	%为BlockRWStream所调用的读写器必须实现的抽象接口类
	%抽象接口类不能直接实例化。您必须针对您要读写的文件实现自己的专用读写器类，继承此类并实现抽象属性和方法。一般来说，一个实例对象只用于读取一个指定的文件；也可以同时
	% 写出到另一个指定的文件。
	%BlockRWStream会控制此对象的生命周期为，从读取第一个数据块开始，到写出最后一个数据块结束（delete）。由于上一个文件完成写出之前，下一个文件可能已经开始读入，同一时
	% 刻可能会有多个对象同时存在。
	%作为示例，此处提供一个简单的视频读取器实现：
	%```
	%classdef BlockVideoReader<ParallelComputing.IBlockRWer&VideoReader
	%	%此类将一个视频的每一帧作为一个数据片，对大视频文件进行分块读入。
	%	properties(SetAccess=immutable)
	%		PieceSize
	%		NumPieces
	%		CollectData
	%		ProcessData={}
	%		%设置一个空元胞以支持BlockRWStream.SpmdRun
	%	end
	%	methods
	%		function obj = BlockVideoReader(VideoPath)
	%			obj@VideoReader(VideoPath);
	%			Sample=obj.readFrame;
	%
	%			%设置一个数据片的尺寸为视频一帧的字节数
	%			obj.PieceSize=numel(typecast(Sample(:),'uint8'));
	%
	%			%数据片的个数就是视频帧数
	%			obj.NumPieces=obj.NumFrames;
	%
	%			%没有元数据就可以不设置CollectData
	%		end
	%		function Data = Read(obj,Start,End)
	%			Data=obj.read(Start:End);
	%		end
	%	end
	%end
	%```
	%数据片指的是一次性必须读入的最小数据单元，小于这个单元的数据将无法处理。每次读入的数据块通常由多个相邻的数据片顺序串联而成，具体串联多少个取决于当前内存状况。例
	% 如，对于视频，一个数据片通常就是一帧。
	%See also ParallelComputing.BlockRWStream

	%属性说明必须单行
	properties(SetAccess=immutable,Abstract)
		%指示每个数据片的字节数。BlockRWStream将根据此属性决定一次要读取多少片。
		PieceSize double
		%指示文件中有多少个数据片。BlockRWStream将根据此属性判断是否已读取完该文件。
		NumPieces double
		%文件特定、无关分块的，需要收集的数据。BlockRWStream将在打开每个文件时收集该数据，然后在CollectReturn时一并返回。如果文件没有需要收集的数据，可以不设置此属性的值。
		CollectData
		%文件特定、在块间共享的，处理过程所必需的数据。如果没有这样的数据，可以不设置此属性的值。但如果要用于BlockRWStream.SpmdRun自动调度，必须指定一个空元胞表示没有数据，否则SpmdRun会将一个空数组作为独立参数。
		ProcessData
	end
	methods(Abstract)
		%必须实现的抽象成员方法，用于读取指定的数据块。
		%BlockRWStream收到 Remote/Local ReadBlock 调用后，将根据PieceSize计算出要读取的数据片起始和终止点，然后调用此方法读取数据块。
		%BlockRWStream保证数据是从头到尾顺序读取的。每次读取数据块的大小不一定相同，但不会有重复或遗漏。您可以根据此顺序性优化读入器的性能。
		%# 重写语法
		% ```
		% function Data=Read(obj,Start,End)
		% end
		% ```
		%# 输入参数
		%Start(1,1)double，起始数据片序号
		%End(1,1)double，终止数据片序号
		%# 返回值
		% Data，从Start到End（含两端）的数据块，将返回给 Remote/Local ReadBlock 的调用方。如果您使用BlockRWStream的SpmdRun方法，此方法可以返回元胞数组，使得每个元胞
		%  存放一个要交给SpmdRun的BlockProcess的参数。如果您指定了SpmdRun的NumGpuArguments参数值为n，则返回元胞数组的前n个元胞内必须是可以转换为gpuArray的数据类型。
		%See also ParallelComputing.BlockRWStream
		Data=Read(obj,Start,End)
	end
	methods
		function Data=Write(~,Data,~,~)
			%可选重写的成员方法，用于写出数据块
			%BlockRWStream收到 Remote/Local WriteBlock 调用后，将会把调用方提供的数据块交给BlockRWStream.WriteReturn方法处理，WriteReturn再将数据筛选后交给此方法写
			% 出文件，并提供读取该数据块时的数据片位置信息。
			%该方法默认不做任何事直接返回原数据块。返回的数据块将被BlockRWStream.WriteReturn取得。如果您需要将处理后的数据块写出到文件，或者有其它自定义操作，可以重
			% 写此方法。
			%BlockRWStream不保证数据是从头到尾顺序写出：先读入的数据块有可能反而较晚被写出。请保证您的写出器支持随机写出。
			%# 重写语法
			% ```
			% function Data=Write(obj,Data,Start,End)
			% end
			% ```
			%# 输入参数
			% Data，要写出的数据块，由BlockRWStream.WriteReturn提供。
			% Start End(1,1)uint16，读取该数据块时的起始和终止数据片位置。因为计算结果的写出不像读入时那样顺序进行，您必须根据Start和End计算出要将结果写出到输出文件
			%  的哪个位置。
			%# 返回值
			% Data，不写出，而是返还给BlockRWStream.WriteReturn的数据项。很多时候您可能只希望将一部分计算结果输出到文件，那么剩余仍留在内存中的部分就返回给
			%  BlockRWStream收集起来，日后调用BlockRWProcess.CollectReturn即可返回这部分数据。
			%See also ParallelComputing.BlockRWStream
		end
	end
end