%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% MAIN BURGERS
% This script computes a feedback control for the Burgers' equations
% using the Dynamical Low Rank Approximation method based on the
% State Dependent Riccati Equation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Setup and Parameters
clear; close all;

if input('Type 1 for Burgers 1D or 2 for Burgers 2D: ') == 1
    run setting_Burgers1D.m
else
    run setting_Burgers2D.m
end

%% Control strategy set
nrmQ = norm(Q, 'fro');
res_A = @(Ay, X) norm(Ay' * X + X * Ay - X * By * X + Q, 'fro') / nrmQ; % Residual for NK solver

% Control solver handle
control_FOM = @(Y, Guess) control_full(A, Q, By, D, Y, Guess,...
    tol_trunc, linesearch, it_linesearch, outer_it,...
    coeff_burger, invRB, res_A);

%% Full-Order Model (FOM) Simulation

    fprintf('Running full-order simulations...\n');
    Y_full     = cell(nt,1);
    control_f  = cell(nt-1,1);
    Pguess     = speye(Nh);
    GuessP_mu0 = Pguess;
    t_start    = tic;


    % Time-stepping
    Y_full{1} = y0;
    for t = 1:nt-1
        fprintf('Time step %d / %d\n', t, nt-1);
        Y_full{t+1} = zeros(Nh, np);
        control_f{t} = zeros(m_B, np);
        for j = 1:np
            Yj = Y_full{t}(:, j);
            [ctrl_j, P, ~, ~] = control_FOM(Yj, select_initial_guess(j, np_kk, Pguess, GuessP_mu0));
            control_f{t}(:, j) = ctrl_j;
            Y_full{t+1}(:, j) = step_rk2(Yj, ctrl_j, dt, A, TT, B);

            % Update Pguess for next parameter
            if mod(j-1, np_kk) == 0
                Pguess = P;
            end
            if j == 1
                GuessP_mu0 = P;
            end
        end
    end

    fprintf('FOM simulation time: %f s\n', toc(t_start));


%% Low-Rank DLRA Initialization

t0 = tic;
[U0, S0, ~] = svd(y0, 'econ');
energies     = diag(S0).^2;
cum_energy   = cumsum(energies) / sum(energies);
l_y0         = find(cum_energy >= 0.9999, 1);
U = U0(:, 1:l_y0);


% Optional Enrichment of the basis
if isRankEnrich
    [~, P0] = control_FOM(y0(:,1), speye(Nh));
    if isP0        % employ the information from the Riccati solution P0
        MM = full(P0);
    else           % employ the information from the feedback matrix K
        K = (-invRB*P0)';
        MM = full(K);
    end
    [Udp2,Sdp2,~] = svd((eye(Nh)-U*U')*MM, 'econ');
    diagSp2 = diag(Sdp2).^2;

    energies     = diag(Sdp2).^2;
    cum_energy   = cumsum(energies) / sum(energies);
    l_dP         = find(cum_energy >= 0.9999, 1);
    l = l_y0+l_dP;
    U = [U Udp2(:,1:l_dP)];
    Z = (U'*y0)';

else
    l = l_y0;
    Z = (U'*y0)';
end

%% Time Integration via DLRA
fprintf('Running DLRA simulation...\n');

Ymid{1} = U*Z';
Usave = cell(nt,1);
Zsave = cell(nt,1);
Usave{1} = U;
Zsave{1} = Z;

NyZ = @(U,Z) (TT*(kron(U,U)))*(compute_Zkron(Z)*Z);
NyU = @(U,Z) (U'*TT*(kron(U,U))*compute_Zkron(Z))';
F2 = @(U,Z,C,control) (eye(Nh)-U*U')*(A*U+(NyZ(U,Z)+control)*pinv(C));
Fz2 = @(U,Z,control) Z*(U'*A'*U)+NyU(U,Z)+control;
Guess_d = eye(l);
umat = @(U,Z,Guess_d,l) control_proj(A,B,Q,By,U,Z',tol_trunc,linesearch,it_linesearch,outer_it,np,np_kk,m_B,invRB,TT,l, Guess_d);
control_dlra = cell(nt-1,1);

for time = 1:nt-1

    C = Z'*Z;

    output = umat(U,Z,Guess_d,l);
    control_dlra{time} = output{3};

    FF = @(U,Z)  F2(U,Z,C,output{2});
    U1 = second_uflow(U,Z,dt,FF);
    Z12 = Z+dt*0.5*Fz2(U,Z,output{1});
    U12 = second_uflow(U,Z,dt/2,FF);
    Z = Z+dt*Fz2(U12,Z12,output{1});
    U = U1;
    Usave{time+1} = U;
    Zsave{time+1} = Z;

    Guess_d = output{4};


end

dlra_time_T = toc(t0);

%% Error computation

err_fro = zeros(nt-1,1);
err_control = zeros(nt-1,1);

for time = 1:nt-1
    Ydlra = Usave{time}*Zsave{time}';
    err_fro(time) = sqrt(dx)*norm(Y_full{time} - Ydlra,'fro')/np;
    err_control(time) = sqrt(dx)*norm(control_f{time} - control_dlra{time},'fro')/np;
end

meanErrState = mean(err_fro);
meanErrCon= mean(err_control);

fprintf('\n Mean error for the state: %g\n', meanErrState);
fprintf('Mean error for the control: %g\n', meanErrCon);

%% Helper functions

function Zkron = compute_Zkron(Z)

np = length(Z(:,1));
r = length(Z(1,:));
Ztilde = Z';
Zkron = zeros(r*r,np);

for mu=1:np
    Zkron(:,mu) = kron(Ztilde(:,mu),Ztilde(:,mu));
end

end

function Guess = select_initial_guess(j, np_kk, Pguess, GuessP_mu0)
% Choose P-matrix initial guess based on parameter index
if j == 1
    Guess = GuessP_mu0;
elseif mod(j-1, np_kk) == 0
    Guess = Pguess;
else
    % reuse previous P (from caller workspace)
    Guess = evalin('caller', 'P');
end
end

function Ynew = step_rk2(Y, u, dt, A, TT, B)
% Two-stage RK2 update for state
Ny = TT * kron(Y, Y);
Fy = A*Y + Ny + B*u;
Y12 = Y + 0.5*dt * Fy;
Ny12 = TT * kron(Y12, Y12);
Fy12 = A*Y12 + Ny12 + B*u;
Ynew = Y + dt * Fy12;
end
